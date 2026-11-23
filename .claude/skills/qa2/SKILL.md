---
name: qa2
description: Record the maintainer's failed in-game test of a pull request that waits for it (tickets In Review with the label in-game-qa), revise the same branch, sync it into the game, have the new head reviewed and hand it back for another test. Only gated (major) changes use it. Use when the user says "qa2" or reports problems from testing in the game.
---

# qa2: changes needed, revise

Follow `CLAUDE.md` (which imports `AGENTS.md`) and read [`docs/ai-development-flow.md`](../../../docs/ai-development-flow.md) completely first; this skill may not weaken either. _qa2: changes needed_ there holds the rules.

When the Jira tools are missing, check again every minute (`AGENTS.md`, Issue Tracking); the code work below can start meanwhile, the ticket steps wait.

1. **Find the batch** as [`qa1`](../qa1/SKILL.md) does, and remove the label `in-game-qa` from its tickets (they wait for the agent now; the handoff in step 6 sets it again). Record his feedback on each affected ticket (a `🤖 Claude QA` comment quoting him with the date), so the reviewer and a later session have it. Then read it: what changes the plan or needs his decision goes back to him as a question in the response, recorded in a comment on the ticket, and is not guessed at.
2. **Stay on the same branch:** no new branch, no new pull request. Reuse its worktree or create one from `origin/<branch>` after `git fetch origin`; bring the local branch up to the remote head first. Commits he pushed himself belong to the batch and are never pushed over. Read the tickets' comments for context the handoff did not repeat (_Reading a ticket_).
3. **Apply his feedback**, and nothing beyond it. A Lua error he pasted is read from its message and stack; never ask him for something `Logs/` or the code already shows.
4. **Check, bump, sync** (_Implementation and verification_): the gate, the version bump of each changed AddOn, then `scripts/sync-addons.sh` so the game has the revision (a cloud session gives him the commands instead). A revision that changes a migration of saved data gets a new version mark, and the backup of his saved data comes before the sync (_Saved data_ in that section).
5. **Push** and read the remote head back. The description keeps its `Do not merge before in-game QA` line.
6. **Review and hand back** through [`finalize-pr`](../finalize-pr/SKILL.md): it runs the independent review of the revision (the reviewer also gets the earlier findings) and performs the _In-game QA handoff_ again. Do not post a second handoff yourself. For a revision that handoff is limited to what changed: the `🎮 In-game QA handoff` comment names the new head and what the revision changed, the tickets stay In Review, and the response ends as `AGENTS.md`, Ending a response says, with `What to test (needed before the merge)` limited to the revision, the bold sync message below it, and the line on how he answers (`qa1`, `qa2`).
