---
name: flow1
description: Autonomously select and deliver a coherent batch of FRV Jira tickets from To Do (board order). Waits for the Jira tools when they are not attached yet, claims the tickets, implements the batch in its own git worktree, checks it, syncs the changed AddOns into the game, opens one pull request and carries it through its independent review with finalize-pr - to the merge, or, for a major change, to the in-game QA handoff that the maintainer answers with qa1 or qa2. Never implements tickets that wait on the maintainer. Takes an optional run location - "flow1 local" (the machine with the game folder, can sync) or "flow1 cloud" (no game folder). Use when the user says "flow1", "flow1 local" or "flow1 cloud", or asks the agent to pick up and deliver ticket work.
---

# flow1: autonomous batch delivery

Follow `CLAUDE.md` (which imports `AGENTS.md`) and read [`docs/ai-development-flow.md`](../../../docs/ai-development-flow.md) completely before selecting work; this skill may not weaken either. Each step names the section of that document that holds its rules.

`flow1` is one autonomous goal. Do not treat it as a request for a single ticket, and do not stop at a report before the batch's pull request is merged or handed over for the in-game test, unless the run reaches a boundary in _Run boundaries_ first.

**Run location** (_Run location_): the argument is `local` or `cloud`. Without one, the run is `local` when the session can sync into the game folder, else `cloud`. Name the mode in the batch announcement.

0. **Jira first.** The Jira tools attach a few minutes after a session starts (`AGENTS.md`, Issue Tracking). When they are missing, check again every minute and start the intake as soon as they are there; never select work without the board, and never report Jira as unavailable after one failed check. After 10 checks tell the maintainer and keep checking.
1. **Intake** (_Intake and batch selection_, steps 1 to 5): reconcile merged tickets; look at what is in flight (tickets, open pull requests, branches, worktrees); read the To Do candidates in board order with their comments (_Reading a ticket_); set aside tickets waiting on the maintainer (_Tickets waiting on the maintainer_), tickets with unmet dependencies (_Dependencies_), `fable-5.2` tickets on another model, tickets the run location cannot do, and tickets for an AddOn that has an open pull request.
2. **Classify** each candidate gated, optional or none (_QA classification_; the rule is `AGENTS.md`, In-Game QA: only major changes are gated, and what is major is your call).
3. **Select and announce** one coherent batch (_Intake and batch selection_, steps 6 and 7).
4. **Claim** every ticket before writing any implementation, and create the batch's one branch and worktree (_Claim_).
5. **Implement** in that worktree, following `AGENTS.md`, the nearest nested guides and `CLAUDE.md`: verify every API against wow-ui-source `forever`, bump the version of every changed AddOn, keep the guides and `README.md` current.
6. **Check and sync** (_Implementation and verification_): the gate on the final head, then `scripts/sync-addons.sh` for the changed AddOns (a cloud run says that the sync did not happen). Report only the commands that actually ran.
7. **Publish** (_Publication_): push, open one ready pull request (a gated batch with its `Do not merge before in-game QA` line), read the remote head back, record `🤖 Claude QA` on each ticket and move the tickets to In Review.
8. **Review and merge, always.** In the same run, run [`finalize-pr`](../finalize-pr/SKILL.md) on that pull request. An optional or none batch ends merged (and, when it touches the feed's paths, with its deploy run finished). A gated batch ends at the _In-game QA handoff_: the maintainer's [`qa1`](../qa1/SKILL.md) merges it, his [`qa2`](../qa2/SKILL.md) gets it revised.
9. **Next batch** only when this one is merged or handed over, and never for an AddOn whose pull request is still open (_Run boundaries_).

Every response of the run, the last one included, ends as `AGENTS.md`, Ending a response says: What changed, What to test with the bold sync message, Verification, and the `Tickets:` line with the keys the run claimed. A question for whatever the run cannot go on without comes before Verification. What only needs recording goes into the tickets' comments.
