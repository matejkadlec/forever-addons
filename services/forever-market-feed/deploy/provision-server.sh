#!/usr/bin/env bash
# Provisions the ForeverMarket feed tenant on the shared production host. Run as root, from a copy of this
# directory, with the public half of the GitHub Actions deploy key:
#
#   sudo ./provision-server.sh ./deploy-key.pub
#
# It creates only what belongs to this tenant and can be run again (to install a changed command or unit, or a
# new key):
#
#   fmf-deploy                                      locked account, no sudo, no extra groups
#   its systemd slice limits                        CPU and memory ceiling for everything it runs
#   its rootless Docker daemon                      user service, started at boot (lingering)
#   /srv/forever-market-feed/                       repository mirror, releases, state, database dumps
#   /etc/forever-market-feed/                       private configuration; the database and backup
#                                                   passwords are generated here and never printed
#   /usr/local/libexec/forever-market-feed-deploy   root-owned forced command of the deploy key
#   /usr/local/libexec/forever-market-feed-backup   root-owned backup command
#   ~fmf-deploy/.config/systemd/user/               backup and monitor units (installed, not enabled)
#   ~fmf-deploy/.ssh/authorized_keys                the deploy key, restricted to the command
#
# It installs no package and changes no host-wide setting (SSH daemon, firewall, system Docker, other accounts);
# when the host lacks something it stops and says what.
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C

readonly ACCOUNT=fmf-deploy
readonly ACCOUNT_HOME="/home/$ACCOUNT"
readonly STATE_ROOT=/srv/forever-market-feed
readonly PRIVATE_ROOT=/etc/forever-market-feed
readonly LIBEXEC=/usr/local/libexec
readonly COMMANDS=(forever-market-feed-deploy forever-market-feed-backup)
# A quarter of the host's eight cores and a small share of its memory, at a lower scheduling weight than the
# sites: an image build may be slow, but it cannot starve them. The containers add up to about 1.9 GB of limits
# (PostgreSQL 512 MB, collector 768 MB, API 512 MB, connector 128 MB), the monthly restore rehearsal adds 512 MB.
readonly SLICE_LIMITS=(CPUQuota=200% CPUWeight=50 MemoryHigh=2560M MemoryMax=3G MemorySwapMax=0)

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

(($# == 1)) || die "usage: $0 <deploy-key.pub>"
# Absolute, because the account's commands below run from /.
source_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
key_source="$(realpath -- "$1")"
readonly source_directory key_source

#------------------------------------------------------------------------------
# Preflight: nothing is changed before all of this holds
#------------------------------------------------------------------------------

((EUID == 0)) || die "run as root"
# shellcheck source=/dev/null
. /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "expected Ubuntu"

for tool in docker dockerd-rootless-setuptool.sh rootlesskit newuidmap newgidmap git flock tar \
  loginctl runuser nsenter python3 restic sha256sum; do
  command -v "$tool" >/dev/null || die "the host has no '$tool' (ask the owner before installing anything host-wide)"
done
docker compose version >/dev/null 2>&1 || die "the host has no Docker Compose plugin"

for name in "${COMMANDS[@]}"; do
  [[ -f "$source_directory/$name" ]] || die "no such file: $source_directory/$name"
  bash -n "$source_directory/$name" || die "$name is not a valid script"
done
units=("$source_directory"/systemd/forever-market-feed-*.service "$source_directory"/systemd/forever-market-feed-*.timer)
[[ -f "${units[0]}" ]] || die "no systemd units beside this script"

[[ -f "$key_source" ]] || die "no such file: $key_source"
(($(grep -c . "$key_source") == 1)) || die "$key_source must hold exactly one public key"
read -r key_type key_blob _ <"$key_source"
[[ "$key_type" == "ssh-ed25519" && "$key_blob" =~ ^[A-Za-z0-9+/=]+$ ]] || die "expected one ssh-ed25519 public key"
ssh-keygen -l -f "$key_source" >/dev/null || die "$key_source is not a valid public key"

#------------------------------------------------------------------------------
# Account: locked password, private group only, own subordinate ID range
#------------------------------------------------------------------------------

if ! id "$ACCOUNT" >/dev/null 2>&1; then
  useradd --create-home --home-dir "$ACCOUNT_HOME" --shell /bin/bash --user-group "$ACCOUNT"
fi
usermod --lock "$ACCOUNT"
chmod 0700 "$ACCOUNT_HOME"

[[ "$(id -Gn "$ACCOUNT")" == "$ACCOUNT" ]] || die "$ACCOUNT must not be in any supplementary group"
grep -Eq "^$ACCOUNT:[0-9]+:65536$" /etc/subuid || die "$ACCOUNT has no subordinate UID range in /etc/subuid"
grep -Eq "^$ACCOUNT:[0-9]+:65536$" /etc/subgid || die "$ACCOUNT has no subordinate GID range in /etc/subgid"
account_uid="$(id -u "$ACCOUNT")"
readonly account_uid

#------------------------------------------------------------------------------
# Directories. The private one must exist before the rootless daemon starts:
# RootlessKit copies /etc into the daemon's mount namespace at that moment, and
# a directory created later would be invisible to bind mounts (the tunnel token
# secret) until the daemon restarts.
#------------------------------------------------------------------------------

install -d -m 0750 -o root -g "$ACCOUNT" "$STATE_ROOT"
install -d -m 0700 -o "$ACCOUNT" -g "$ACCOUNT" \
  "$STATE_ROOT/repository" "$STATE_ROOT/releases" "$STATE_ROOT/state" "$STATE_ROOT/backups"
install -d -m 0700 -o "$ACCOUNT" -g "$ACCOUNT" "$PRIVATE_ROOT"

#------------------------------------------------------------------------------
# Secrets, generated once and straight into their private files. An existing
# file is never replaced: the database passwords are also stored inside the
# PostgreSQL volume, and the restic password is the only key to the backups.
# Nobody needs the database passwords: only the containers use them.
#------------------------------------------------------------------------------

random_hex() { head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }

# write_private <file> <content>
write_private() {
  local target="$PRIVATE_ROOT/$1"
  [[ ! -e "$target" ]] || return 0
  (umask 077 && printf '%s' "$2" >"$target.new")
  chown "$ACCOUNT:$ACCOUNT" "$target.new"
  chmod 0600 "$target.new"
  mv -- "$target.new" "$target"
  echo "generated $target"
}
# The owner role: POSTGRES_PASSWORD for PostgreSQL itself, PGPASSWORD for the collector.
password="$(random_hex 32)"
write_private postgres.env "POSTGRES_PASSWORD=$password"$'\n'"PGPASSWORD=$password"$'\n'
# The read-only role of the API; `forever-market-feed-deploy init` sets it on the role.
write_private api-database.env "PGPASSWORD=$(random_hex 32)"$'\n'
write_private restic-password "$(random_hex 32)"$'\n'
unset password

#------------------------------------------------------------------------------
# Rootless Docker daemon of the account, kept running across reboots by lingering
#------------------------------------------------------------------------------

loginctl enable-linger "$ACCOUNT"
for _ in $(seq 1 30); do
  [[ -S "/run/user/$account_uid/bus" ]] && break
  sleep 1
done
[[ -S "/run/user/$account_uid/bus" ]] || die "the systemd user manager of $ACCOUNT did not start"

#------------------------------------------------------------------------------
# Resource ceiling of the tenant, set before its Docker daemon is started.
# `set-property` writes a drop-in for this account's slice alone and applies it
# at once; every process of the account, its Docker daemon, containers and
# image builds included, lives below it.
#------------------------------------------------------------------------------

systemctl set-property "user-$account_uid.slice" "${SLICE_LIMITS[@]}"

as_account=(
  runuser -u "$ACCOUNT" -- env
  HOME="$ACCOUNT_HOME"
  USER="$ACCOUNT"
  LOGNAME="$ACCOUNT"
  XDG_RUNTIME_DIR="/run/user/$account_uid"
  DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$account_uid/bus"
  DOCKER_HOST="unix:///run/user/$account_uid/docker.sock"
  PATH=/usr/local/bin:/usr/bin:/bin
)
cd /

if [[ ! -f "$ACCOUNT_HOME/.config/systemd/user/docker.service" ]]; then
  "${as_account[@]}" dockerd-rootless-setuptool.sh install
fi
"${as_account[@]}" systemctl --user enable --now docker.service

for _ in $(seq 1 30); do
  "${as_account[@]}" docker info >/dev/null 2>&1 && break
  sleep 1
done
"${as_account[@]}" docker info --format '{{json .SecurityOptions}}' | grep -Fq 'name=rootless' ||
  die "the Docker daemon of $ACCOUNT does not report rootless mode"

daemon_pid="$(<"/run/user/$account_uid/dockerd-rootless/child_pid")"
[[ "$daemon_pid" =~ ^[1-9][0-9]*$ ]] || die "cannot find the rootless daemon process"
runuser -u "$ACCOUNT" -- nsenter --user --preserve-credentials --mount --target "$daemon_pid" \
  test -d "$PRIVATE_ROOT" || die "the rootless daemon cannot see $PRIVATE_ROOT; restart its docker.service"

# Without the cpu controller delegated to the account's user manager the containers' CPU limits are not enforced.
grep -qw cpu "/sys/fs/cgroup/user.slice/user-$account_uid.slice/user@$account_uid.service/cgroup.controllers" ||
  die "the cpu cgroup controller is not delegated to $ACCOUNT"

#------------------------------------------------------------------------------
# Commands, units, and the key that may run nothing but the deploy command
#------------------------------------------------------------------------------

[[ -d "$LIBEXEC" ]] || install -d -m 0755 -o root -g root "$LIBEXEC"
for name in "${COMMANDS[@]}"; do
  install -m 0755 -o root -g root "$source_directory/$name" "$LIBEXEC/$name"
done

# Installed but not enabled: the backup timers are switched on by hand once the bucket is configured and a first
# backup, check and rehearsal have passed, the monitor once the first deployment is healthy.
unit_directory="$ACCOUNT_HOME/.config/systemd/user"
install -d -m 0700 -o "$ACCOUNT" -g "$ACCOUNT" "$ACCOUNT_HOME/.config" "$ACCOUNT_HOME/.config/systemd" "$unit_directory"
for unit in "${units[@]}"; do
  install -m 0644 -o "$ACCOUNT" -g "$ACCOUNT" "$unit" "$unit_directory/$(basename "$unit")"
done
"${as_account[@]}" systemctl --user daemon-reload

install -d -m 0700 -o "$ACCOUNT" -g "$ACCOUNT" "$ACCOUNT_HOME/.ssh"
authorized_keys="$ACCOUNT_HOME/.ssh/authorized_keys"
printf 'command="%s",restrict %s %s forever-market-feed-github-actions\n' "$LIBEXEC/forever-market-feed-deploy" "$key_type" "$key_blob" \
  >"$authorized_keys.new"
chown "$ACCOUNT:$ACCOUNT" "$authorized_keys.new"
chmod 0600 "$authorized_keys.new"
mv -- "$authorized_keys.new" "$authorized_keys"

#------------------------------------------------------------------------------
# Summary (metadata only)
#------------------------------------------------------------------------------

echo "Provisioned:"
id "$ACCOUNT"
passwd --status "$ACCOUNT" | awk '{print "password status: " $2}'
grep -E "^$ACCOUNT:" /etc/subuid | sed 's/^/subuid: /'
systemctl show "user-$account_uid.slice" -p CPUQuotaPerSecUSec -p CPUWeight -p MemoryHigh -p MemoryMax -p MemorySwapMax |
  tr '\n' ' ' | sed 's/^/slice: /'
echo
echo "linger: $(loginctl show-user "$ACCOUNT" -p Linger --value)"
echo "delegated controllers: $(<"/sys/fs/cgroup/user.slice/user-$account_uid.slice/user@$account_uid.service/cgroup.controllers")"
stat -c '%a %U:%G %n' "$ACCOUNT_HOME" "$ACCOUNT_HOME/.ssh" "$authorized_keys" \
  "$STATE_ROOT" "$STATE_ROOT"/* "$PRIVATE_ROOT" "$PRIVATE_ROOT"/* \
  "$LIBEXEC/forever-market-feed-deploy" "$LIBEXEC/forever-market-feed-backup"
"${as_account[@]}" docker info --format 'docker {{.ServerVersion}}, {{.CgroupDriver}} cgroup driver, cgroup v{{.CgroupVersion}}'
"${as_account[@]}" systemctl --user list-unit-files 'forever-market-feed-*' --no-legend --no-pager
