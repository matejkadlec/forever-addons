---
name: finalize-pr
description: Carry one of your own pull requests in matejkadlec/forever-addons through its independent review to its merge. Each round uses a fresh, read-only pr-reviewer subagent; this session verifies and fixes the findings, re-reviews, waits for the checks, and merges with a merge commit once a review of the exact head is clean and the checks are green - unless the pull request waits for the maintainer (his in-game test of a major change, a step on the host, his decision), in which case it hands over and stops. After a merge that touches the feed's paths it follows the deploy run. Keeps the FRV tickets in step. Runs after every pull request a session publishes or updates. Use when the user types "finalize-pr 12", and right after publishing or updating a pull request.
---

# finalize-pr: independent review, then the merge

The rules are [`AGENTS.md`, Pull Requests and Code Review](../../../AGENTS.md#pull-requests-and-code-review); this skill is the procedure and may not weaken them. [`docs/ai-development-flow.md`](../../../docs/ai-development-flow.md) holds the handoff (_In-game QA handoff_) and the ticket rules. This is the only skill that merges.

## When it runs

- The maintainer says `finalize-pr <n>`.
- Right after a session publishes or updates a pull request as its own task work, in every case: no pull request is too small or too docs-only for it.

The run is not finished at a clean review or a green check. It ends only at one of the Stops below.

## Scope

- One pull request in `matejkadlec/forever-addons`. Before every write check `git remote get-url origin`.
- **Only your own pull requests are merged:** GitHub shows `matejkadlec` as the author, the head branch is in this repository (not a fork), and the Claude Code attribution ends the description. Anyone else's pull request is reviewed on request and reported, never fixed, pushed to or merged.
- It fixes verified findings on the branch, pushes that branch, comments on the pull request, merges, follows the feed deploy run and keeps the tickets in step. It never deploys by hand, re-runs the deploy workflow, touches the feed's host, weakens a check, or uses `--no-verify`, `--admin` or auto-merge.
- Never mention a bot account (`@...`) on the pull request: GitHub treats a mention as a request to it.
- Never read or print `.env` files, tokens or the feed server's private configuration, and never put them into a review bundle, a comment or a report.

## Start

1. **Resolve the target:** `gh pr view <n> --json number,title,url,state,isDraft,isCrossRepository,author,headRefName,headRefOid,baseRefName,body`. Closed or merged: go to Stops. Not your own: review only. A pull request whose base is another branch (work stacked on an open pull request) is reviewed against that base and merged only after the base has merged and it was retargeted to `master`.
2. **Locate the worktree:** `git fetch origin`, then reuse the worktree `git worktree list` shows for the head branch or create one (`AGENTS.md`, Branches and Worktrees). Uncommitted changes or local commits that are not yours: change nothing and ask.
3. **Note the holds** from the description and the changed files (`gh pr diff <n> --name-only`):
   - **In-game QA:** the description says `Do not merge before in-game QA`. When it does not, the author's classification stands (a doubtful case is the optional kind, `AGENTS.md`, In-Game QA); add the line yourself only when the change is plainly major, no `In-game QA passed on <sha>` is recorded and the maintainer has not said that he does not want to test it;
   - **Maintainer:** a step on the host, a new secret or config file, his decision, any other "do not merge before ..." note;
   - **Feed deploy:** the diff touches `services/forever-market-feed/**` or `.github/workflows/market-feed.yml`, so the merge deploys the server and the pull request's `Checks` run must appear and pass first.
4. **Jira:** when the tools are missing, check again every minute (`AGENTS.md`, Issue Tracking). The review does not wait for Jira; the ticket steps do.

## Review round

1. **Build the review bundle** in the session's scratchpad directory, never inside the repository: the whole diff `git diff origin/<base>...HEAD` (three dots, after a fetch); for a later round also the diff since the last reviewed head and the earlier findings with what was done about each; a short metadata file with the pull request's title, the tickets' descriptions and comments (the maintainer's request, his `qa2` feedback included), the head SHA, the worktree path and the path of a wow-ui-source `forever` clone (`untracked/wow-ui-source` in the main checkout; clone it when it is missing).
2. **Start a fresh reviewer:** the Agent tool with `subagent_type: pr-reviewer`, one new agent per round, never a continued one and never a fork. Give it the bundle paths and the worktree root, and nothing of your own reasoning about why the change is right.
   - A session that started before `.claude/agents/pr-reviewer.md` existed cannot start that type. Then use a fresh general-purpose agent, give it `.claude/agents/pr-reviewer.md` to read as its instructions and tell it that it is read-only.
3. **Verify every finding** against the code yourself before acting on it:
   - valid P1 and P2: fix on the branch, one commit per root cause;
   - valid P3: fix it when it is small and inside the pull request's scope, else create a follow-up ticket (flow document, _Issues_, Follow-ups) or drop it with a concrete technical reason;
   - wrong, or against the maintainer's request, or needing his decision: do not apply it. Note it in a pull request comment with your reason. For a P1 or P2 the round has then not passed and the pull request stays open until the maintainer answers: stop under User needed (`AGENTS.md`: you never overrule the reviewer alone). When he confirms the rejection, record his answer in that pull request comment; the round then counts as passed for that head. When he sides with the reviewer, fix it and run a new round. A rejected P3 needs only its recorded reason; a P3 that needs his decision becomes a follow-up ticket labelled `decision` and does not hold the merge.
4. **After fixes:** run the gate (flow document, _Implementation and verification_), bump versions where AddOn files changed, sync the changed AddOns into the game, push once, read the remote head back, and run another round on the new head.
5. **A round passes** when the reviewer reports nothing that needs a change (no P1 and no P2; a round with a rejected P1 or P2 has not passed). The last passing round before a merge must have covered the whole diff against `origin/master` on the exact head that is merged. After five rounds without a pass, stop under User needed with the open findings.
6. **Record the pass:** a pull request comment `Independent review clean on <sha> (whole diff against origin/master)` that also lists each round's findings and what was done about them (fixed in `<sha>`, ticketed, dropped or rejected with the reason), so a later session can give them to the next reviewer. In a later session that record counts as the passing round for the same head; a new round runs only when the head moved.

## Checks

Read `gh api repos/matejkadlec/forever-addons/commits/<head sha>/check-runs`. No check runs counts as green, except with a feed deploy hold, where the `Checks` run is waited for. Pending runs are waited for. A failing run is read (`gh run view <id> --log-failed`) and fixed on the branch like a finding; it is never re-run to get a different answer and never worked around.

## Handoff instead of a merge

With an in-game QA hold, do not merge. The hold is closed by a recorded pass (`🎮 In-game QA passed` on the tickets, `In-game QA passed on <sha>` in the description) for the current head, or for an earlier head when no AddOn file changed since (`git diff --name-only <sha>..HEAD -- addons backports`, the top level guide files aside); [`qa1`](../qa1/SKILL.md) records it. While the hold is open: once the round passed and the checks are green, sync the head's AddOns into the game, set the label `in-game-qa` and a `🎮 In-game QA handoff` comment on each ticket (the head, `independent review clean on <sha>`, what to test, `/reload` or restart; after a `qa2` limited to what the revision changed), and end the response with `What to test (needed before the merge)` (flow document, _In-game QA handoff_). The run continues when he answers `qa1` or `qa2`.

## Merge

All of these hold: a passing round covers the exact head and the whole diff; the checks are green; no hold is open; the branch has no conflict with `master` (your own branch: rebase onto `origin/master`, push with `--force-with-lease`, and review the new head again; a shared branch: merge `origin/master` in).

`gh pr merge <n> --merge --match-head-commit <sha>`: a merge commit, the way the maintainer merges. Then confirm `state: MERGED` and note the merge commit.

## After the merge

1. **Tickets:** each one gets a `🤖 Claude QA` line with the merge commit and moves to Done; the label `in-game-qa` is gone.
2. **Feed deploy:** when the merge touched the feed's paths, find the `Market feed` run for the merge commit (`gh run list --workflow market-feed.yml --branch master`), follow it to its end and report the result. A failed run is reported to the maintainer at once with the failing step; nothing is re-run and the host is not touched.
3. **Cleanup:** remove the batch's worktree and local branch when they hold no uncommitted changes (`AGENTS.md`, Branches and Worktrees: your own, or the batch you merged).

## Stops

- **Merged** (and a feed deploy finished): report and stop.
- **Handed over** for the in-game test: report in the What to test shape and stop until `qa1` or `qa2`.
- **User needed:** a maintainer hold, a rejected P1 or P2 finding, a P1 or P2 finding that needs his decision, five rounds without a pass, a failing check that needs something only he can change, a failed deploy. Say exactly what he has to do and where; the pull request stays open.
- **Not your own pull request:** report the review, change nothing.
- **Closed unmerged, or merged by someone else:** report; after a foreign merge still do After the merge.

## Report

Every response ends as [`AGENTS.md`, Ending a response](../../../AGENTS.md#ending-a-response) says. Verification names each review round with its verdict and what happened to every finding (fixed in `<sha>`, ticketed as `FRV-<n>`, dropped or rejected with the reason), the gate's commands, the check runs on the head, the merge commit and the deploy run. Never "all checks passed" for a partial run.
