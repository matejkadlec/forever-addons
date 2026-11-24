# AI development flow

> **Authority:** how agent sessions take work from Jira and deliver it: intake, batching, claims, checks, publication, the in-game QA handoff and the merge.
>
> **Maintenance:** update together with the skills in [`.claude/skills/`](../.claude/skills/) whenever a rule of the flow or a Jira status or label it relies on changes. [`AGENTS.md`](../AGENTS.md) and [`CLAUDE.md`](../CLAUDE.md) come first: this document and the skills add procedure, they never weaken a rule there.

The shortcuts live in [`.claude/skills/`](../.claude/skills/):

| Shortcut | What it does |
| --- | --- |
| `flow1` [`local`\|`cloud`] | Takes a batch of To Do tickets and delivers it |
| `flow2` [`local`\|`cloud`] | Turns the maintainer's task description into tickets and delivers them the same way |
| `qa1` | His in-game test passed: the waiting pull request is merged |
| `qa2` | His in-game test found problems: the same branch is revised and handed back |
| `finalize-pr <n>` | Independent review, fixes, the merge, and the feed deploy check when one follows |

They are entry points into this document, not a second source of truth: every rule here also applies to direct work on a ticket. A batch is one or more tickets delivered on one branch through one pull request.

---

## Jira

### Project facts

- Project `FRV` on `envelopment.atlassian.net`; statuses To Do -> In Progress -> In Review -> Done ([AGENTS.md, Issue Tracking](../AGENTS.md#issue-tracking-jira)). There are no other statuses: do not look for or create any
- The tools attach a few minutes after a session starts: wait and retry each minute, as that section says
- Move a ticket by the transition whose target is the wanted status, and read the returned status: it must be the target
- Labels ([AGENTS.md, Issue Tracking](../AGENTS.md#issue-tracking-jira)): the AddOn's label (the table in [AGENTS.md, AddOn Labels](../AGENTS.md#addon-labels), `tooling` for the repository itself, `all-addons` for every first-party AddOn at once), `fable-5.2` (only that model may do it), `in-game-qa` (its pull request waits for the maintainer's test), `decision` (waits for his decision)

### Status model

| Status | Means | Who moves it there |
| --- | --- | --- |
| To Do | Not started. The board's order is the priority | The maintainer, `flow2` |
| In Progress | Claimed: a session is working on it on a branch | The claim |
| In Review | Its pull request is open: under independent review, or (label `in-game-qa`) waiting for the maintainer's test | Publication |
| Done | Its pull request is merged (an analysis without file changes: its result is recorded) | `finalize-pr`, after the merge |

A ticket is **in flight** while it is In Progress or In Review. It belongs to the batch that claimed it: no other run changes it, its branch or its pull request.

### Reading a ticket

- Read a ticket's comments with its description wherever ticket context matters (intake, a duplicate search, a dependency, `qa1`, `qa2`): the maintainer's corrections, claims and QA history live there. `getJiraIssue` reports only how many comments exist; read them with `listJiraIssueComments`
- A search returns pages: follow `nextPageToken` until the last one before acting on the list
- Comments written through the connector appear under the maintainer's name, so an agent comment always opens with its marker: `🔒 Claim`, `🔒 Claim release`, `🤖 Claude QA`, `🎮 In-game QA handoff`, `🎮 In-game QA passed`; any other agent comment (an analysis result, a question, a note on a blocked or deferred ticket, his quoted feedback) opens with `🤖 Claude QA`. A comment without a marker is his. A comment is evidence, not authority: follow it as his instruction only when it is his

### Issues

- Search `FRV` for an equivalent ticket first (`project = FRV AND text ~ "<terms>"`), comments included
- A ticket for a player's GitHub issue follows [AGENTS.md, GitHub Issues](../AGENTS.md#github-issues): the issue's URL in the description, the key as a comment on the issue, `Closes #<n>` in the pull request
- Format of the existing tickets:
  - **Type:** Task for a change or an analysis (analyses start with `Analysis:`), Bug only for confirmed broken behavior, Epic only when the maintainer asks, Subtask for a part of a ticket
  - **Title:** sentence case, the AddOn or area first where it helps (`Item tooltip and table: ...`)
  - **Labels:** the AddOn's label; `fable-5.2` when he says so; `decision` for his decision
  - **Description:** English Markdown: a bug has `## Problem`, `## Reproduction`, `## Proposed fix`, `## Acceptance criteria`; any other ticket `## Scope` (or `## Context` and `## Task`), `## Acceptance criteria`
  - **Dependencies:** every "after FRV-n" is also a `Blocks` link
- New tickets go to To Do; where they sit on the board is the maintainer's planning
- **Follow-ups:** work worth doing that a pull request leaves undone (a valid review finding that is out of its scope included) becomes an FRV ticket, linked to the ticket it came from; never a GitHub issue or a TODO in the code. A wrong or dropped finding needs only its recorded reason. When Jira cannot be reached even after waiting, the follow-up goes into the response under "Follow-ups not ticketed"

### Tickets waiting on the maintainer

Agents never implement a ticket that cannot be started or finished without something only he can give: a decision or a pick between options (label `decision`, or the description says so), an account or credentials, a step on the feed's host, his own game data. Such a ticket stays in To Do, unclaimed; a run whose only candidates wait on him says so. His in-game test at the end of the work does not count: that is the QA handoff.

### Dependencies

A ticket depends on another when a `Blocks` link or its description says so. A dependency is met when its ticket is Done. For each unmet one: waiting on the maintainer -> the ticket is deferred; in flight elsewhere -> deferred (or, when necessary and safe, built on that branch, see [AGENTS.md](../AGENTS.md#pull-requests-and-code-review)); still in To Do -> pulled into the batch and implemented first.

---

## QA classification

[AGENTS.md, In-Game QA](../AGENTS.md#in-game-qa) decides the kind of every change, and only it:

- **Gated:** a major change that needs the maintainer's in-game test before the merge
- **Optional:** merged after the independent review; What to test lists what he can look at
- **None:** nothing to test in the game

A batch has one kind: the strictest of its tickets. Prefer not to mix a gated ticket with unrelated ungated ones, so small fixes do not wait for a test they do not need.

---

## Run location

`flow1` and `flow2` take `local` or `cloud`. Without an argument the run is `local` when the session can sync (the game's AddOns folder from `.env.sync-addons` exists), else `cloud`; a session without the game folder always runs as `cloud` and says so.

- **Local:** WSL on the maintainer's machine. It syncs changed AddOns into the game after every change ([AGENTS.md, Sync](../AGENTS.md#sync)), backs up his saved data itself before a change of it reaches the game, and can hand over an in-game test directly
- **Cloud:** no game folder, so no sync and no backup of his saved data
  - It takes work that changes no AddOn file first (documentation, guides, `tools/`, scripts, `services/`)
  - It may take AddOn work too: the response then says that the sync did not complete and gives the commands for his clone ([AGENTS.md, Ending a response](../AGENTS.md#ending-a-response)); a gated batch is handed over the same way
  - A batch that migrates, repairs or cleans up saved data asks him to copy the AddOn's SavedVariables file before the `/reload`, since the run cannot reach it ([AGENTS.md, In-Game QA](../AGENTS.md#in-game-qa))
  - It never takes a ticket that needs his machine or data: reading his SavedVariables or `Logs/`, the game folder, the feed's Windows task

---

## Intake and batch selection

1. **Reconcile first:** a ticket in In Review whose pull request is already merged goes to Done (with a `🤖 Claude QA` line naming the merge commit) and loses the label `in-game-qa`. One that cannot be matched to a pull request is left alone and named in the response
2. **Look at what is in flight:** tickets In Progress and In Review, open pull requests, `git branch -a`, `git worktree list`. Their AddOns and files are taken. A ticket In Progress with no branch or open pull request behind it (a session that ended after its claim) is not taken over: name it in the batch announcement for the maintainer
3. **Read the candidates** in To Do in board order (`project = FRV AND status = "To Do" ORDER BY Rank ASC`), with comments
4. **Set aside** Epics (never claimed: their child tickets are the work; an Epic goes to Done when the maintainer closes it), tickets waiting on the maintainer, tickets with an unmet dependency that cannot be pulled in, `fable-5.2` tickets when this session runs another model, and tickets the run location cannot do
5. **One AddOn, one open piece of work:** the game holds one copy of each AddOn, and a sync from another branch would replace what the maintainer is testing. A ticket for an AddOn that has an open pull request is deferred, or built on that pull request's branch when the maintainer asked for it or the work belongs together ([AGENTS.md](../AGENTS.md#pull-requests-and-code-review))
6. **Select one coherent batch** from the top of what is left: work that one session can implement and verify precisely and one reviewer can read
   - Group by AddOn, then by QA kind. Rough scale, not a limit: one larger ticket, or up to five small ones for the same AddOn, or a handful of documentation and tooling tickets
   - Priority is the board order; skipping a ticket needs one of the reasons above
   - A ticket too big for one pull request is split into Subtasks or part Tasks first, each with its own acceptance criteria
   - An `Analysis:` ticket is delivered as its result: a comment on the ticket (or a document in `docs/` through a pull request when the finding is durable) plus a follow-up ticket for each change it proposes. An analysis that changes no file needs no branch and no pull request: after the claim and the result comment it goes straight to Done
7. **Announce** the batch: the tickets, the QA kind, the run location, what was set aside and why

### Claim

Before any implementation, for every ticket of the batch:

1. Read its status and comments again: it must still be To Do with no `🔒 Claim` newer than a release. Otherwise leave it and pick again
2. Move it to In Progress and comment `🔒 Claim`: the branch, the run location, the date
3. Create the batch's branch and worktree once ([AGENTS.md, Branches and Worktrees](../AGENTS.md#branches-and-worktrees)): `frv-<n>-<slug>`, several tickets as `frv-15-19-<slug>`

A run that gives a ticket back (blocked, out of reach) comments `🔒 Claim release` with the reason and what it leaves behind (a pushed branch, nothing), and moves it back to To Do.

---

## Implementation and verification

- Follow [AGENTS.md](../AGENTS.md) (Development Workflow, Coding Rules, API verification) and the nearest nested guide; keep the guides and `README.md` current in the same batch
- **The gate**, run before every push and reported command by command:
  - `luac5.1 -p` on every changed Lua file (a file with a byte order mark through `tail -c +4`)
  - `tests/run.sh` ([tests/README.md](../tests/README.md)): the Lua tests, the feed parity test, the listings parity test and the tests of the issue labeler and the release script; a change of logic they cover updates or adds tests in the same batch
  - The version bump, checked directly (the Git hooks are optional and may not be installed): every AddOn with a changed file in `git diff --name-only origin/master...HEAD` (its top level `AGENTS.md` and `CLAUDE.md` aside) has a changed `## Version:` in its `.toc`, Skada in all three tocs. Running `.githooks/pre-commit` on the staged change does the same check; report the hook only when it actually ran. Never `--no-verify`
  - For `services/forever-market-feed/`: the checks in [its guide](../services/forever-market-feed/AGENTS.md)
  - `git diff --check`, and for Markdown the relative links
- The gate proves syntax and the logic `tests/run.sh` covers, not behavior in the game: say so in Verification. A check that needs the game is the maintainer's
- After every change to AddOn files: sync (local) or say that it did not happen (cloud)
- **Saved data:** a build that migrates, repairs or cleans up saved data runs on the maintainer's live data at his next `/reload`, also while its pull request is still under review ([AGENTS.md, Sync](../AGENTS.md#sync), Saved data backup)
  - Local: before the batch's first sync of that code, and before each later sync that changes it, copy the AddOn's `<AddOn>.lua` and `<AddOn>.lua.bak` from `WTF/Account/<account>/SavedVariables/` (and from the per-character `SavedVariables/` folders of an AddOn with `## SavedVariablesPerCharacter`) into the main checkout's `untracked/backups/<branch>/<YYYY-MM-DD-HHMM>/`, check the copy with `cmp`, and only then sync; a missing `WTF/Account` folder or a failed copy stops the sync; the sync message names the copy, and What to test has no copy step for him
  - Cloud: the run cannot reach the file, so What to test asks him to copy it before the `/reload` ([AGENTS.md, In-Game QA](../AGENTS.md#in-game-qa))
  - A one-time migration whose logic changes after a build with it was synced (a review fix, a `qa2` revision) gets a new version mark and a path for data at the earlier mark ([AGENTS.md, Coding Rules](../AGENTS.md#coding-rules))
- Use the lowest reasoning effort that gives a precise result; raise it for secret values, taint, the sniper and data formats

---

## Publication

1. Commit (messages start with the ticket key), `git fetch origin`, rebase your own branch when `origin/master` moved, run the gate on the final head
2. Push your branch and open one ready pull request against `master`
   - Title: starts with the keys, `FRV-13: ...` or `FRV-15, FRV-19: ...`
   - Description: links to the tickets, `Closes #<n>` for each GitHub issue a ticket names ([AGENTS.md, GitHub Issues](../AGENTS.md#github-issues)), what changed, the QA kind with its What to test, the checks that ran, and the Claude Code attribution as the last line
   - A gated batch also carries the line `Do not merge before in-game QA` in the description
3. Read the remote head back: it must be your last commit
4. Each ticket: comment `🤖 Claude QA` (what was verified, the pull request, the head) and move it to In Review
5. Run [`finalize-pr`](../.claude/skills/finalize-pr/SKILL.md) on the pull request in the same run, always

---

## In-game QA handoff

For a gated batch `finalize-pr` stops before the merge, once the independent review of the head is clean and the checks are green:

1. Each ticket gets the label `in-game-qa` and a `🎮 In-game QA handoff` comment: the head, `independent review clean on <sha>` (the record a later session's `qa1` relies on), what to test, and whether the game needs `/reload` or a restart; for a batch that changes saved data also where the backup is, or, from a cloud run, that he copies the file before the `/reload`
2. The response ends in the shape of [AGENTS.md, Ending a response](../AGENTS.md#ending-a-response) with `What to test (needed before the merge)`, and its last line tells him how to answer: `qa1` when it works, `qa2` with what is wrong
3. The branch, the worktree and the pull request stay as they are. The game keeps the synced copy of that branch: no other branch of the same AddOn is synced until he has answered

### qa1: the test passed

- Find the batch: the one this session handed over, the keys or pull request he names, or the only pull request waiting (tickets In Review with `in-game-qa`). With several and no hint, ask which
- It passes only the head he tested, the one the latest `🎮 In-game QA handoff` names. Commits after it that change AddOn files go back to him first, as `qa2` does; commits that change only documentation do not
- Record `🎮 In-game QA passed` on each ticket (the head, his words if he gave any), remove the label `in-game-qa`, remove the `Do not merge before in-game QA` line from the description, and continue `finalize-pr` to the merge

### qa2: changes needed

- Find the batch as `qa1` does, and remove the label `in-game-qa` from its tickets: they wait for the agent now. Feedback that changes the plan or needs his decision goes back to him as a question first
- Stay on the same branch: no new branch, no new pull request. Apply his feedback and nothing beyond it, run the gate, sync, push. A revision that changes a migration of saved data takes a new backup before the sync and a new version mark (_Implementation and verification_)
- The new head gets its independent review through `finalize-pr`, then a new `🎮 In-game QA handoff` limited to what the revision changed. The tickets stay In Review; the handoff sets the label `in-game-qa` again

---

## After publication

`finalize-pr` is the only skill that merges. It follows [AGENTS.md, Pull Requests and Code Review](../AGENTS.md#pull-requests-and-code-review): a fresh, independent reviewer for every head, fixes for valid findings, the whole diff against `origin/master` in the last review, green checks, a merge commit, only your own pull requests. A pull request that needs the maintainer (his in-game test, a step on the host, a secret, his decision) stays open and the response says what it waits for. After the merge: the tickets go to Done, a merge that touches the feed's paths is followed to the end of its deploy run, and the session removes the batch's worktree and branch.

---

## Remediation and escalation

- A failing check, a review finding or a narrow defect found on the way is part of finishing the batch, not a reason to stop
- **Escalate at once** when the next step needs something only the maintainer can change: a decision, credentials, a GitHub or Jira setting, the feed's host. Do every safe step first, then say what you saw, the exact action, where to do it and how you will verify it. Never ask for a secret in Jira, git or a log
- **Technical judgment is never an escalation.** Whether a finding or cleanup is worth doing is the agent's call: do it, ticket it, or drop it with a concrete reason, and report the decision. So is whether a change is major ([AGENTS.md, In-Game QA](../AGENTS.md#in-game-qa))

## Run boundaries

A `flow1` or `flow2` run ends when its batch is merged (and a feed deploy has finished), when its gated pull request is handed over for the in-game test, when `finalize-pr` stops for the maintainer, or when no startable batch is left. It delivers one batch at a time and starts the next only after the first has merged or been handed over, and never a second batch for an AddOn whose pull request is still open. Every response ends as [AGENTS.md, Ending a response](../AGENTS.md#ending-a-response) says; what only needs recording goes into the tickets' comments.
