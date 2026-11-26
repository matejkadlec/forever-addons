---
name: flow2
description: Turn the maintainer's task description into FRV Jira tickets (the existing ticket format - type, AddOn label, an "Acceptance criteria" section, English), claim them and deliver them right away through the flow1 lifecycle - worktree, checks, sync into the game, one pull request, independent review, then the merge or, for a major change, the in-game QA handoff for qa1 or qa2. Waits for the Jira tools when they are not attached yet. Takes an optional run location - "flow2 local" or "flow2 cloud". Use when the user describes a task and says "flow2", "flow2 local" or "flow2 cloud".
---

# flow2: capture, then deliver

Follow `CLAUDE.md` (which imports `AGENTS.md`) and read [`docs/ai-development-flow.md`](../../../docs/ai-development-flow.md) completely before creating or selecting work; this skill may not weaken either.

**Run location** (_Run location_): as in [`flow1`](../flow1/SKILL.md). Both modes capture every requested item as a ticket; a `cloud` run delivers only what it can do without the maintainer's machine and leaves the rest in To Do with a comment saying so.

0. **Jira first.** When the Jira tools are missing, check again every minute and start as soon as they are there (`AGENTS.md`, Issue Tracking). Reading the code and planning can go on meanwhile; no branch is created and nothing is implemented before the tickets exist.
1. **Analyze** every requested item and search `FRV` for duplicates, comments included (_Issues_, _Reading a ticket_). Start with the reconciliation of merged tickets (_Intake and batch selection_, step 1), so a finished ticket reads as Done in that search.
2. **Create or update tickets** under _Issues_: one per deliverable piece, in the existing format, with the AddOn's label, its priority (the one he names, else the default of _Issues_) and a `Blocks` link for each dependency. Preserve everything he asked for; merge only true duplicates. Never update a ticket that is in flight (_Status model_): create a follow-up linked to it, or tell him the work is already under way there.
3. **Set aside** what is his own decision: such an item becomes a ticket with the label `decision` and goes to him as a question in the response, not implemented (_Tickets waiting on the maintainer_).
4. **Classify** each ticket gated, optional or none (_QA classification_).
5. **Check** in-flight work, dependencies and the one-AddOn rule exactly as `flow1` step 1 does. A ticket this run just created is claimed like any other; creating it grants no ownership.
6. **Claim, implement, check, sync, publish, finalize, clean up** as `flow1` steps 4 to 9: a merged batch ends with its remote branch (unless GitHub already deleted it), its worktree and its local branch removed and `git fetch --prune` run; a given back or withdrawn one records its branch's tip SHA on the tickets before the same cleanup (`AGENTS.md`, Branches and Worktrees). Requested items that fit one coherent batch go into one pull request; unrelated ones, or a gated one next to small ungated ones, are delivered as separate batches one after another (_Run boundaries_).
7. **Leave blocked tickets** in To Do with the exact dependency recorded (a `Blocks` link and a comment).

Every response ends as `AGENTS.md`, Ending a response says, and its `Tickets:` line names every ticket the run created or worked on.
