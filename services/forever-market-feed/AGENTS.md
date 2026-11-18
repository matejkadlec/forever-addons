# ForeverMarket Feed (`services/forever-market-feed/`)

> **Scope:** the feed service, its deploy files and `.github/workflows/market-feed.yml`. The root [`AGENTS.md`](../../AGENTS.md) (Jira, worktrees, pull requests and code review) applies here.
>
> **Maintenance:** update this guide when the service's shape, checks or deploy path change. This guide and the `CLAUDE.md` next to it lie under the workflow's path filter: a merge that changes only them still runs `Checks` and redeploys the server (same code), so treat it as a deploy. [`README.md`](README.md) in this folder is the documentation; this guide only holds the rules.

---

## What it is

- Python, stdlib only (the server image adds `psycopg`, pinned in `requirements.lock`)
- Reads the auction house from the Battle.net API (namespace `dynamic-forever-{region}`, `/data/wow/ruleset/{id}/auctions/{house}` + `/commodities`) and writes the load-on-demand AddOn `ForeverMarket_Feed` straight into the game folder (generated, not in the repo, never synced)
- Its port of `scan/Diff.lua` / `FM.FinalizeSnapshot` must stay in step with ForeverMarket's record format: change both sides in the same change (see [`addons/ForeverMarket/AGENTS.md`](../../addons/ForeverMarket/AGENTS.md))
- In server mode `server.py` collects into PostgreSQL on the shared host `matejkadlec-cz1` (tenant `fmf-deploy`, API `https://market.matejkadlec.cz/v1/`) and the PC pulls from it

## Rules

- `.github/workflows/market-feed.yml` deploys master when `services/forever-market-feed/**` or the workflow itself changes: **a merge is a production deploy**
  - After such a merge: say so, check the workflow run and report a failed run to the maintainer
  - A pull request touching these paths waits for its `Checks` run to appear and pass before it may be merged
  - A pull request that needs the maintainer first (a step on the host, a new secret or config file, his decision) is not merged: leave it open and tell him what it waits for
- The service README's Server section documents the tenant, secrets, deploys, backups and restore, and must be kept current with `compose.yml` and `deploy/`
- The host is shared with other sites: change only what the README lists as this service's, and ask the maintainer before anything host-wide
- Never commit `.env.market-feed`, the private configuration of the server (`collector.env`, `api.env`, `cloudflared-token`, ...), run state or logs; never print them either
- `*.cmd` and `*.vbs` keep CRLF line endings, `*.task.xml` is UTF-16 (`.gitattributes`): do not rewrite them with other encodings

## Checks before a pull request

The workflow's `Checks` job runs these; run what your environment has before pushing:

```bash
python3 -m py_compile feed.py server.py
shellcheck deploy/provision-server.sh deploy/forever-market-feed-deploy deploy/forever-market-feed-backup
```

The Compose file and the image build are checked by the workflow (they need Docker).
