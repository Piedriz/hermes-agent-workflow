# hermes-runtime-scripts/

Agent-runtime callables — Python scripts and shell helpers invoked by
cron jobs or by skills at runtime. Distinct from `scripts/` at the
repo root (which holds install / bootstrap / sync helpers that operate
ON your hermes install).

## How this dir is wired

`scripts/bootstrap.sh` symlinks this dir into your live hermes layout:

```
~/.hermes/scripts/  →  <your-fork>/hermes-runtime-scripts/
```

Any script you (or the agent) drops into `~/.hermes/scripts/` lands in
your fork automatically and survives:

- Host migrations (you clone the fork onto a new machine; bootstrap
  recreates the symlink; the script comes along for the ride)
- Re-installs (same)
- Accidental rm of `~/.hermes/` (you re-clone, re-bootstrap, scripts
  are back)

## What goes here

Examples of things skills + cron jobs put here:

- **`notion_daily_planner_rollover.py`** — invoked by a cron job to
  roll yesterday's unchecked TODOs into today's Notion daily-planner
  page. Skill at `skills/productivity/notion-daily-planner-rollover/`
  documents the cron, env vars, and repair workflow.
- **Skill-shipped helpers** — Python or shell scripts a skill calls
  via `subprocess` / `bash -c`. The skill's SKILL.md should reference
  the script by its `~/.hermes/scripts/<name>` runtime path; the
  symlink resolves that to here.

What does NOT go here:

- Install / bootstrap / sync / doctor scripts (those live in
  `scripts/` at the repo root)
- Skill bodies themselves (those live under `skills/<category>/<name>/`)
- One-off / dev-only scripts (use `/tmp` or a personal dotfile dir)

## How a new script ends up tracked

1. Agent or you writes a file at `~/.hermes/scripts/foo.py`
2. Symlink resolves it to `<your-fork>/hermes-runtime-scripts/foo.py`
3. `git add hermes-runtime-scripts/foo.py` + commit + push
4. Other hosts pull, bootstrap (if not yet symlinked), script is live.

## Post-mortem (2026-05-11)

This dir exists because of a field bug: on the first host migration
of the original install (blueberry → cortex), `~/.hermes/scripts/`
wasn't in the symlink list. The notion daily-planner script lived
there as a real file. When the new host came up, the dir was empty,
the cron ran a missing path silently for two days, and the user only
noticed when their Notion page stopped getting daily updates.

The recovery skill regenerated the script from its memory of what it
should do, but anyone whose runtime scripts have local-only data
(API keys baked in, page IDs, etc.) would have lost that. Symlinking
this dir into the repo means a script's BODY lives in versioned
storage from the moment it's created — same lifecycle as your other
versioned state.
