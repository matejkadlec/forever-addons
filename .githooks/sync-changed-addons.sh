#!/usr/bin/env bash
# Shared by the post-commit and post-merge hooks: sync the AddOns touched by a range of commits.
# Usage: .githooks/sync-changed-addons.sh <from-ref> <to-ref>
# Does nothing when .env.sync-addons is missing, so the hooks are harmless for other contributors.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
if [[ ! -f "$REPO_ROOT/.env.sync-addons" ]]; then
    exit 0
fi

from_ref="${1:-}"
to_ref="${2:-HEAD}"

# List changed files NUL-separated (keeps non-ASCII paths unquoted)
ListChangedFiles() {
    if [[ -n "$from_ref" ]] && git rev-parse --verify --quiet "$from_ref" >/dev/null; then
        git diff --no-renames --name-only -z "$from_ref" "$to_ref"
    else
        # first commit or unknown range: everything in the target commit
        git diff-tree --no-renames --root --no-commit-id --name-only -r -z "$to_ref"
    fi
}

declare -A addon_names=()
declare -A removed_names=()
while IFS= read -r -d '' file; do
    case "$file" in
        addons/*/*|backports/*/*)
            group="${file%%/*}"
            rest="${file#*/}"
            name="${rest%%/*}"
            if [[ -d "$REPO_ROOT/$group/$name" ]]; then
                addon_names["$name"]=1
            else
                # deleted or renamed AddOns cannot be synced
                removed_names["$name"]=1
            fi
            ;;
    esac
done < <(ListChangedFiles)

for name in "${!removed_names[@]}"; do
    if [[ -z "${addon_names[$name]:-}" ]]; then
        echo "AddOn $name was removed or renamed in the repository, delete its old folder from your AddOns folder manually." >&2
    fi
done

if [[ ${#addon_names[@]} -eq 0 ]]; then
    exit 0
fi

echo "Syncing changed AddOns into WoW: ${!addon_names[*]}"
if ! "$REPO_ROOT/scripts/sync-addons.sh" "${!addon_names[@]}"; then
    echo "AddOn sync failed, sync the changed AddOns manually." >&2
fi
exit 0
