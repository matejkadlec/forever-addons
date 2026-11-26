# Reusable Workflows

The repository's shared rules live in [AGENTS.md](AGENTS.md) and the nearest nested guide. Claude Code sessions also read [CLAUDE.md](CLAUDE.md), which imports `AGENTS.md`. This file is an index of how the common tasks are done; every rule it names is defined in those guides, not here.

## Deliver Jira work (skills)

The delivery skills live in [`.claude/skills/`](.claude/skills/) and take every rule from [docs/ai-development-flow.md](docs/ai-development-flow.md):

- `flow1` [`local`|`cloud`]: take a batch of To Do tickets from `FRV` and deliver it
- `flow2` [`local`|`cloud`]: turn a task description into `FRV` tickets and deliver them
- `qa1` / `qa2`: the maintainer's answer to an in-game test of a major change: merge it, or revise it
- `finalize-pr <n>`: the independent review by the read-only [`pr-reviewer`](.claude/agents/pr-reviewer.md), the fixes, the merge, and the feed deploy check

The steps below are what those skills do, for work done without them.

## Deliver a change (ticket to merge)

1. **Ticket:** find or create the FRV ticket, label it, give a new one its priority ([docs/ai-development-flow.md](docs/ai-development-flow.md#issues)), move it to In Progress ([Issue Tracking](AGENTS.md#issue-tracking-jira)). Jira tools missing at session start: wait and retry each minute
2. **Worktree:** a branch named after the ticket, in its own worktree from a fresh `origin/master` ([Branches and Worktrees](AGENTS.md#branches-and-worktrees))
3. **Implement:** follow the [Development Workflow](AGENTS.md#development-workflow) and the nearest nested guide
4. **Check:** `luac5.1 -p` on every changed Lua file, `tests/run.sh` ([tests/README.md](tests/README.md)), the version bump of every changed AddOn, the documentation
5. **Sync** the changed AddOns into the game ([Communication Rules](AGENTS.md#communication-rules)) and classify the change: his test before the merge, an optional test, or nothing to test ([In-Game QA](AGENTS.md#in-game-qa))
6. **Pull request:** title starts with the ticket key and links the ticket; move the ticket to In Review
7. **Independent review**, fixes, then merge your own pull request once the review and the checks pass ([Pull Requests and Code Review](AGENTS.md#pull-requests-and-code-review)); a change that needs the maintainer's in-game test waits for his answer first; move the ticket to Done and remove your worktree
8. **End the response** with What changed, What to test, Verification and Tickets ([Communication Rules](AGENTS.md#ending-a-response))

## Take in a GitHub issue

When the maintainer asks: read the issue (its form's AddOn, versions, steps, errors), create its FRV ticket with the AddOn's label and the issue's URL, comment the key on the issue, and deliver the ticket as above with `Closes #<n>` in the pull request ([GitHub Issues](AGENTS.md#github-issues)). A duplicate or a question is answered and closed on GitHub, without a ticket.

## Verify an API

1. Clone or update `untracked/wow-ui-source` (`forever` branch, [Core Rules](AGENTS.md#core-rules-very-important))
2. Search `Interface/AddOns/Blizzard_APIDocumentationGenerated/` for the function or event; check `Camelot/` overrides before `Mainline/`
3. Read its flags: `SecretWhen...` / `SecretReturns` need `issecretvalue` guards, `HasRestrictions` means user actions only and never in combat
4. Not found: treat it as unsupported and say so
5. Record a finding other AddOns will need in [docs/forever-api-notes.md](docs/forever-api-notes.md) ([docs/AGENTS.md](docs/AGENTS.md))

## Change a first-party AddOn

Read [addons/AGENTS.md](addons/AGENTS.md) (and [addons/ForeverMarket/AGENTS.md](addons/ForeverMarket/AGENTS.md) for ForeverMarket, [addons/ForeverCraftQueue/AGENTS.md](addons/ForeverCraftQueue/AGENTS.md) for ForeverCraftQueue, [addons/ForeverEnhancedMailbox/AGENTS.md](addons/ForeverEnhancedMailbox/AGENTS.md) for ForeverEnhancedMailbox). Keep the chat, slash command and settings panel conventions; everything settable by slash command is also in the panel. Bump `## Version:`, update the inventory and `README.md` when user-facing behavior changes, sync.

## Add a first-party AddOn

Name, shortname, required `.toc` fields (`## X-License: All Rights Reserved` among them; a copy of the root `LICENSE` in its folder once it is released on its own), icon, settings panel and slash command as in [addons/AGENTS.md](addons/AGENTS.md). Add it to the inventory in [AGENTS.md](AGENTS.md), to the icon and slash command lists in the nested guide and to `README.md`, and give it its label in Jira and on GitHub, its option in both issue forms and in the labeler ([AddOn Labels](AGENTS.md#addon-labels)); `tests/run.sh` checks the forms and the labeler. A new AddOn needs a game restart, not `/reload`, and the maintainer's in-game test before the merge.

## Fix or add a backported AddOn

Read [backports/AGENTS.md](backports/AGENTS.md): conservative compatibility fixes, original name, commands and style kept, license respected, `.toc` attribution marked. Record the port change in that guide's port details and in `README.md` under `Backported AddOns`. A new backport keeps its license file in its folder (README, Licenses) and gets its label and issue form options like a new first-party AddOn ([AddOn Labels](AGENTS.md#addon-labels)).

## Change the feed service

Read [services/forever-market-feed/AGENTS.md](services/forever-market-feed/AGENTS.md). A merge deploys the server: wait for the pull request's `Checks` run, and after the merge check the workflow run and report a failure. A record format change is made in ForeverMarket and in the service together.

## Sync AddOns into the game

`scripts/sync-addons.sh <AddOnName> [...]` after every change to AddOn files, from a worktree with `ENV_FILE=<main checkout>/.env.sync-addons`. Before a build that migrates, repairs or cleans up saved data is synced, the agent copies the AddOn's SavedVariables into the main checkout's `untracked/backups/` ([Sync](AGENTS.md#sync)). A renamed or removed AddOn's old folder is deleted from the game's AddOns folder by hand. Then the bold message: `/reload`, or restart the game when the client must read something again at startup (a new AddOn, files added or removed, a `.toc` field other than the version); a version bump alone needs only `/reload`.
