@AGENTS.md

# Forever AddOns: Claude Code guide

[`AGENTS.md`](AGENTS.md), imported above, is the shared guide for every agent and comes first. This file adds only what Claude Code sessions need on top of it; it never weakens it. Nested guides (`addons/AGENTS.md`, `backports/AGENTS.md`, ...) are not imported: read the nearest one before changing a subtree ([Guide Map](AGENTS.md#guide-map)). [`SKILLS.md`](SKILLS.md) lists the workflows.

- **Owner:** Matěj (the maintainer). Agents do most of the implementation; he sets direction, plans in Jira and tests the AddOns in the game. **Communicate in English** in the repository, Jira and pull requests.

## Hooks

The shared configuration is versioned in [`.claude/settings.json`](.claude/settings.json); personal overrides go to `.claude/settings.local.json` (ignored by Git).

- `PostToolUse` on `Edit`, `MultiEdit` and `Write`: [`.claude/hooks/check-edited-file.sh`](.claude/hooks/check-edited-file.sh) checks the edited file
  - `*.lua`: `luac5.1 -p` (skipped when no Lua 5.1 compiler is installed; `sudo apt install lua5.1` provides it)
  - `services/forever-market-feed/**/*.py`: Python syntax
  - A failure comes back as the hook's error: fix the file before going on
- The hook is only the fast first signal for syntax. It does not know the WoW API: verifying APIs against wow-ui-source, secret value guards and taint rules stay your job

## Jira tools

- The Atlassian tools come from the claude.ai connector and are deferred: find them with `ToolSearch` (query `atlassian jira`), the site is `envelopment.atlassian.net`
- They attach a few minutes after the session starts ([Issue Tracking](AGENTS.md#issue-tracking-jira)). When `ToolSearch` finds none:
  1. Start a background `sleep 60` (Bash with `run_in_background`); foreground sleeps are blocked
  2. When it finishes, run `ToolSearch` again; repeat up to 10 times
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

- The change summary and the bold sync message from [Communication Rules](AGENTS.md#communication-rules) close every response that changed a file
- Say what was verified and how (which checks ran, what the review found); never "all checks passed" for a partial run
