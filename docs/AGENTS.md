# Documentation (`docs/`)

> **Scope:** the maintained documents under `docs/`. The root [`AGENTS.md`](../AGENTS.md) applies here and cannot be weakened by a topic document.
>
> **Maintenance:** update this guide when documentation ownership changes; add every new document to [`README.md`](README.md) in the same change.

## Ownership

- [`README.md`](README.md) is the index: it records which file is authoritative for each topic
- Prefer updating the one authoritative document over copying the same fact into several guides
- Jira project `FRV` is the source for tasks and planning; durable technical findings belong in a document, not only in a Jira comment
- User-facing descriptions of the AddOns belong in the root `README.md` (and `addons/ForeverMarket/README.md`), not here

## `forever-api-notes.md`

- It lists **verified** Forever-specific behavior: every entry was checked against the `forever` branch of wow-ui-source or in the live client
- Say how a fact was verified when it matters, and mark what is assumed or not yet verified in game as such (the file already does: "not yet verified in game")
- Add a finding when you verify something an AddOn depends on (a secret value source, a restriction, a missing or changed API); correct an entry when the client proves it wrong
- Never add an API from memory or from retail documentation alone

## Writing

- Describe the current repository; use paths and commands that exist in the tree
- Use relative links for repository files and check that every linked target exists
- Documentation-only changes: run `git diff --check` and read the rendered headings, tables and links once
