# Per-host state directory

Each physical host that contributes to the same repo gets its own
directory under `hosts/`. The pattern lets you sync from multiple
machines (e.g. a Pi + a laptop) into one repo without conflicts.

Rename this directory from `example-host` to your machine's hostname,
and set `HOST_NAME` in the environment so `scripts/*.sh` write into
the right subtree.

## Subdirectories

### `claude-code/`
Snapshot of `~/.claude/projects/<your-project>/*.jsonl` — the Claude
Code session transcripts. Populated by `scripts/sync-cc-history.sh`
(typically every 15 min via cron). Append-only — never `--delete`.

### `claude-code-memory/`
Snapshot of `~/.claude/projects/<your-project>/memory/*.md` — the
auto-curated memory the Claude Code session writes about itself.
Populated by `scripts/sync-cc-history.sh`. Synced with `--delete` so
renames + retirements propagate.

Other machines can read-through to this directory via symlink so a
laptop's Claude Code session sees the Pi's accumulated memory.

## What does NOT belong here

- Live SQLite indexes (`*.db`, `*.db-shm`, `*.db-wal`) — gitignored.
- Tool-result subdirs from Claude Code — too large, not useful in repo.
- Secrets — those go in encrypted top-level files (see `.gitattributes`).
