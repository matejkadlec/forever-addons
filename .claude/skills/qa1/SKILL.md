---
name: qa1
description: Record the maintainer's passed in-game test of a pull request that waits for it (tickets In Review with the label in-game-qa), remove the hold and carry the pull request to its merge with finalize-pr. Only gated (major) changes use it. Use when the user says "qa1" or says that what he tested in the game works.
---

# qa1: the in-game test passed, merge

Follow `CLAUDE.md` (which imports `AGENTS.md`) and read [`docs/ai-development-flow.md`](../../../docs/ai-development-flow.md) completely first; this skill may not weaken either. _qa1: the test passed_ there holds the rules.

When the Jira tools are missing, check again every minute and continue as soon as they are there (`AGENTS.md`, Issue Tracking); the GitHub steps below do not wait for Jira, the ticket steps do.

1. **Find the batch** he passed: the one this session handed over, the ticket keys or pull request he names, or the only pull request that waits for a test (tickets In Review with `in-game-qa`, the description says `Do not merge before in-game QA`). With several and no hint, ask which one, listing each with its tickets and pull request. Nothing waiting: say so and stop. When a `qa2` left a decision question open on the tickets, ask him to answer it first, or to confirm that his `qa1` accepts the batch as it is.
2. **Check the head he tested.** `git fetch origin`; the head he tested is the one the latest `🎮 In-game QA handoff` comment names. When the pull request moved on since then and the new commits change AddOn files, his test does not cover them: sync, hand those back for another test as [`qa2`](../qa2/SKILL.md) does, and merge nothing. Commits that change only documentation or guides do not need a retest.
3. **Record and release:** on each ticket a `🎮 In-game QA passed` comment (the head, his words if he gave any) and remove the label `in-game-qa`; remove the `Do not merge before in-game QA` line from the pull request description and add `In-game QA passed on <sha>`.
4. **Merge through [`finalize-pr`](../finalize-pr/SKILL.md)**, in the same run: it checks that an independent review covers the exact head and the checks are green, merges, moves the tickets to Done, follows a feed deploy, and cleans up the batch: the remote branch (unless GitHub already deleted it), the worktree, the local branch, `git fetch --prune` (`AGENTS.md`, Branches and Worktrees). The independent review needs no new round when the head is the one the handoff recorded as `independent review clean on <sha>`. A handed-over run counts as stopped, so a `qa1` in a new session continues without asking; ask him first only when another session is visibly still working on the pull request (commits newer than the latest handoff, a review round in progress).

End the response as `AGENTS.md`, Ending a response says.
