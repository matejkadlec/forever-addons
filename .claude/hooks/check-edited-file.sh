#!/usr/bin/env bash
# Claude Code PostToolUse hook: syntax check of the one file an edit just touched.
#   *.lua                                  -> luac5.1 -p (the Lua 5.1 dialect WoW uses)
#   services/forever-market-feed/**/*.py   -> Python parse (no bytecode written)
# Exit code 2 sends the error back to Claude so it fixes it at once. A missing tool or any other file is
# skipped silently. The file is matched by its own path, not by the project directory, so edits in a
# git worktree next to the main checkout are checked too.
set -uo pipefail

file_path="$(python3 -c 'import json, sys; print(json.load(sys.stdin).get("tool_input", {}).get("file_path", ""))' 2>/dev/null || true)"
[[ -n "$file_path" && -f "$file_path" ]] || exit 0

Fail() {
  {
    printf '%s failed after editing %s:\n' "$1" "$file_path"
    printf '%s\n' "$2"
  } >&2
  exit 2
}

case "$file_path" in
  # reference clones (wow-ui-source and others) are not ours to check
  */untracked/*) exit 0 ;;
  *.lua)
    # luac5.1 is the Debian/Ubuntu name; a plain luac only counts when it is 5.1
    if command -v luac5.1 >/dev/null 2>&1; then
      luac_bin="luac5.1"
    elif command -v luac >/dev/null 2>&1 && luac -v 2>&1 | grep -q '^Lua 5\.1'; then
      luac_bin="luac"
    else
      exit 0
    fi
    output="$("$luac_bin" -p "$file_path" 2>&1)" || Fail "$luac_bin -p" "$output"
    ;;
  */services/forever-market-feed/*.py)
    command -v python3 >/dev/null 2>&1 || exit 0
    output="$(python3 -c 'import ast, sys; ast.parse(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1])' "$file_path" 2>&1)" \
      || Fail "Python syntax check" "$output"
    ;;
esac
exit 0
