# Forever AddOns Documentation

This index names the maintained source for each topic. Jira project `FRV` is the source for tasks and planning.

| Topic | Authoritative document | Holds |
| ----- | ---------------------- | ----- |
| Repository rules for agents | [`../AGENTS.md`](../AGENTS.md) | API verification, coding rules, inventory, automatic sync, Jira, worktrees, pull requests and code review |
| Claude Code specifics | [`../CLAUDE.md`](../CLAUDE.md) | What Claude Code sessions need on top of `AGENTS.md`: hooks, Jira tools, worktrees, the reviewer |
| Reusable workflows | [`../SKILLS.md`](../SKILLS.md) | How the common tasks are done, step by step |
| Contributing | [`../CONTRIBUTING.md`](../CONTRIBUTING.md) | For outside contributors: issue first, pull requests, the rules for code in short, checks, the development sync and the Git hooks |
| GitHub issues and labels | [`../AGENTS.md`](../AGENTS.md#github-issues) | The issue forms and their labeler, the AddOn labels shared by Jira and GitHub, how an issue reaches Jira |
| Releasing an AddOn | [`releasing.md`](releasing.md) | The `Release` workflow: a tag `<AddOnFolder>-v<version>` to a zip, a GitHub release and a CurseForge file; the CurseForge token and project ID, a release step by step, what to check afterwards, failed runs |
| AI development flow | [`ai-development-flow.md`](ai-development-flow.md) | Jira intake, batches, claims, checks, publication, the in-game QA handoff and the merge rules behind the skills in `.claude/skills/` |
| First-party AddOn conventions | [`../addons/AGENTS.md`](../addons/AGENTS.md) | Naming and `.toc`, chat messages, settings panels, slash commands |
| ForeverMarket | [`../addons/ForeverMarket/AGENTS.md`](../addons/ForeverMarket/AGENTS.md), [`../addons/ForeverMarket/README.md`](../addons/ForeverMarket/README.md) | Agent inventory; user documentation and data format |
| ForeverCraftQueue | [`../addons/ForeverCraftQueue/AGENTS.md`](../addons/ForeverCraftQueue/AGENTS.md) | Files, the profession window it hooks, Process queue's steps, saved data |
| ForeverEnhancedMailbox | [`../addons/ForeverEnhancedMailbox/AGENTS.md`](../addons/ForeverEnhancedMailbox/AGENTS.md) | Files, the mail frame it hooks, a collection's steps and stops, the safety rules |
| Backported AddOns | [`../backports/AGENTS.md`](../backports/AGENTS.md) | Backport rules and port details |
| ForeverMarket feed | [`../services/forever-market-feed/AGENTS.md`](../services/forever-market-feed/AGENTS.md), [`../services/forever-market-feed/README.md`](../services/forever-market-feed/README.md) | Rules; setup, server, deploys, backups |
| Forever API behavior | [`forever-api-notes.md`](forever-api-notes.md) | Verified Forever-specific findings: secret values, restrictions, missing APIs, taint |
| Documentation rules | [`AGENTS.md`](AGENTS.md) | Ownership and writing rules for `docs/` |

The root [`README.md`](../README.md) is the public introduction for visitors: getting and installing the AddOns, what each does, feedback through the issue forms, the licenses; [`../CONTRIBUTING.md`](../CONTRIBUTING.md) is the contributors' part.
