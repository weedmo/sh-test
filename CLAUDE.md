# Repo conventions

## Git workflow — no worktrees in this repo

**Do not use `git worktree add` or the Claude `EnterWorktree` tool here.**
Work directly on the main checkout:

```sh
git checkout -b feature/<name>
# ... edit ...
git add . && git commit -m "..."
git checkout main && git merge --ff-only feature/<name>
git push origin main
```

**Why this rule exists**

- This repo is a small bash setup-script collection. There is no parallel
  multi-branch development that benefits from worktree isolation.
- A worktree under `.claude/worktrees/<name>` contains a `.git` *file*
  (not directory) that git treats as a gitlink (mode 160000). `git add .`
  from the main checkout will silently stage the worktree as a fake
  submodule, leaving stale commit pointers in history — this has already
  happened once.
- `.gitignore` excludes `.claude/worktrees/` to defend against re-occurrence.

If you genuinely need an isolated branch (e.g. risky refactor while another
branch is mid-flight), use `git stash` + `git checkout` instead of a worktree.

**Optional — silence the Claude Code background-session worktree guard.**
Background Claude sessions auto-isolate writes into a worktree unless you
opt out. To opt out for this repo, add to `.claude/settings.json` (not
committed here; this is a per-user choice):

```json
{ "worktree": { "bgIsolation": "none" } }
```

## Scripts in this repo

- `setup-docker.sh` — Docker Engine + Compose installer for Ubuntu 24.04.
- `setup-laptop.sh` — orchestrator for laptop / always-on Docker host tuning.
  Runs `phases/*.sh` in order. See `./setup-laptop.sh --help`.
- `lib/common.sh` — shared shell helpers (log/warn/die, idempotent
  `write_file`, platform detection). Sourced by every phase.

All setup scripts must be **idempotent**: re-running them must not break the
host or recreate already-applied state. Use `lib/common.sh` helpers
(`write_file`, `backup_once`, `enable_now`) rather than raw `cp` / `echo >`.
