#!/usr/bin/env bash
# Runs every test that needs no game client: the Lua tests (lua5.1), the feed service's parity
# test and the parity test of fm_analyze.py's reader of your listings (python3) on the shared
# fixtures in tests/fixtures/. Every part always runs; the exit code is non-zero when any fails.
# Usage: tests/run.sh (from anywhere in the repository)
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

for tool in lua5.1 python3; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "$tool is missing (sudo apt install lua5.1 python3)" >&2
        exit 1
    fi
done

status=0

echo "== Lua tests"
lua5.1 tests/run.lua tests/*/*_test.lua || status=1

echo "== Feed parity tests"
python3 -B tests/feed/test_feed.py || status=1

echo "== Listings parity tests"
python3 -B tests/tools/test_listings.py || status=1

if [ "$status" -ne 0 ]; then
    echo "Tests FAILED" >&2
fi
exit "$status"
