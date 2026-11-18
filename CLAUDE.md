@AGENTS.md

# Forever AddOns: Claude Code guide

[`AGENTS.md`](AGENTS.md), imported above, is the shared guide for every agent and comes first. This file adds only what Claude Code sessions need on top of it; it never weakens it. Nested guides (`addons/AGENTS.md`, `backports/AGENTS.md`, ...) are not imported here; each has a one line `CLAUDE.md` next to it that Claude Code loads when it reads files in that folder. Do not rely on that alone (a subagent or a worktree path may not get it): read the nearest nested guide before changing a subtree ([Guide Map](AGENTS.md#guide-map)). [`SKILLS.md`](SKILLS.md) lists the workflows.

- **Owner:** Matěj (the maintainer). Agents do most of the implementation; he sets direction, plans in Jira and tests the AddOns in the game. **Communicate in English** in the repository, Jira and pull requests.

## Hooks

The shared configuration is versioned in [`.claude/settings.json`](.claude/settings.json); personal overrides go to `.claude/settings.local.json` (ignored by Git).

- `PostToolUse` on `Edit`, `MultiEdit` and `Write`: [`.claude/hooks/check-edited-file.sh`](.claude/hooks/check-edited-file.sh) checks the edited file
  - `*.lua`: `luac5.1 -p` (skipped when no Lua 5.1 compiler is installed; `sudo apt install lua5.1` provides it); a leading UTF-8 byte order mark is skipped, WoW accepts it
  - `services/forever-market-feed/**/*.py`: Python syntax
  - A failure comes back as the hook's error: fix the file before going on
- The hook is only the fast first signal for syntax. It does not know the WoW API: verifying APIs against wow-ui-source, secret value guards and taint rules stay your job

## Jira tools

- The Atlassian tools come from the claude.ai connector and are deferred: find them with `ToolSearch` (query `atlassian jira`), the site is `envelopment.atlassian.net`
- They attach a few minutes after the session starts ([Issue Tracking](AGENTS.md#issue-tracking-jira)). When `ToolSearch` finds none:
  1. Start a background `sleep 60` (Bash with `run_in_background`); foreground sleeps are blocked
  2. When it finishes, run `ToolSearch` again; repeat every minute, and after 10 empty checks tell the maintainer and keep checking
  3. Meanwhile do the work that needs no Jira; as soon as the tools are there, do the Jira step (ticket first, then the branch named after it)
- An empty first `ToolSearch` is the normal state of a new session, not an error to report

## Worktrees

- Work in `../forever-addons-worktrees/<branch>` ([Branches and Worktrees](AGENTS.md#branches-and-worktrees)); the session's working directory stays the main checkout, so use absolute paths into the worktree for every file tool and `cd` into it in every Bash call
- The hooks above run from the main checkout but check any edited file by its own path, so worktree edits are covered
- The worktree has no `.env.sync-addons`: sync with `ENV_FILE=/home/matej/projects/forever-addons/.env.sync-addons scripts/sync-addons.sh <AddOnName>` (the path of the maintainer's main checkout)
- Claude Code's own session worktrees live in `.claude/worktrees/` (ignored by Git)

## Independent review

- The reviewer required by [Pull Requests and Code Review](AGENTS.md#pull-requests-and-code-review) is a fresh subagent (Agent tool, not a fork: a fork inherits the author's reasoning)
- Give it the diff (`git diff origin/master...<branch>` after a fetch), the worktree path, the maintainer's request and the guides to read; do not give it your own explanation of why the change is right
- Verify each finding yourself before fixing or rejecting it

## Ending a response

- Every response that changed a file ends with What changed, What to test (with the bold sync message below its heading), Verification and the `Tickets:` line, as [Communication Rules](AGENTS.md#ending-a-response) defines them
- That includes intermediate responses of a long task: each one reports what it changed and verified itself
