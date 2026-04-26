#!/usr/bin/env bash
# Snapshot Claude Code session transcripts + auto-memory into this repo so
# (a) a host crash doesn't take history with it, and (b) other machines'
# Claude Code can read-through via symlink to the repo's
# hosts/<HOST_NAME>/claude-code-memory/ dir. Idempotent, cron-safe.
#
# Sources:
#   ~/.claude/projects/<PROJECT_DIR>/*.jsonl     (Claude Code transcripts)
#   ~/.claude/projects/<PROJECT_DIR>/memory/*.md (Claude Code auto-memory)
#
# Destination: hosts/<HOST_NAME>/{claude-code, claude-code-memory}/
#
# The hosts/<hostname>/ pattern lets multiple machines share one repo —
# each writes into its own subtree.
#
# Only .jsonl (+ .md for memory) files are copied. SQLite indexes,
# tool-results subdirs, and symlink targets are deliberately skipped.
#
# No --delete on the session path: archive semantics (if upstream prunes,
# keep the archived copy). DO --delete on memory so renames + retirements
# propagate cleanly — memory is a small curated set, not an archive.
#
# IMPORTANT: this script ONLY READS from ~/.claude/. Never write there;
# the live Claude Code process owns those paths.
#
# Environment overrides:
#   REPO          — path to this repo (default: parent of scripts/)
#   HOST_NAME     — host directory under hosts/ (default: example-host)
#   CC_PROJECT_DIR — claude code project dir (default: -home-$USER)
set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
HOST_NAME="${HOST_NAME:-example-host}"
CC_PROJECT_DIR="${CC_PROJECT_DIR:--home-${USER}}"
SRC_CLAUDE_CODE="${SRC_CLAUDE_CODE:-$HOME/.claude/projects/${CC_PROJECT_DIR}/}"
SRC_CLAUDE_MEMORY="${SRC_CLAUDE_MEMORY:-$HOME/.claude/projects/${CC_PROJECT_DIR}/memory/}"
DST_CLAUDE_CODE="${REPO}/hosts/${HOST_NAME}/claude-code/"
DST_CLAUDE_MEMORY="${REPO}/hosts/${HOST_NAME}/claude-code-memory/"

mkdir -p "${DST_CLAUDE_CODE}" "${DST_CLAUDE_MEMORY}"

rsync -a \
  --include="*.jsonl" \
  --exclude="*" \
  "${SRC_CLAUDE_CODE}" "${DST_CLAUDE_CODE}"

# Memory dir is a symlink; -L follows it to copy file contents, not the link.
rsync -aL --delete \
  --include="*.md" \
  --exclude="*" \
  "${SRC_CLAUDE_MEMORY}" "${DST_CLAUDE_MEMORY}"

cd "${REPO}"

# Path-scoped stage: never touch other tracked paths the user is hand-editing.
git add hosts/

if git diff --cached --quiet; then
  exit 0
fi

git commit -m "sync: cc history snapshot $(date -u +%Y-%m-%dT%H:%MZ)" >/dev/null

if ! git push origin main 2>/dev/null; then
  echo "[sync-cc-history] push failed; will retry next cycle" >&2
  exit 0
fi
