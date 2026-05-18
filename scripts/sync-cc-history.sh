#!/usr/bin/env bash
# Snapshot Claude Code auto-memory into this repo. Host-aware: each host
# writes to its OWN hosts/<HOST_NAME>/claude-code-memory/ subdir, so
# multiple hosts can run this cron concurrently without collision.
# Idempotent, cron-safe.
#
# Sources (Claude Code's auto-memory):
#   ~/.claude/projects/<PROJECT_DIR>/memory/*.md
#
# Destination: hosts/<HOST_NAME>/claude-code-memory/
#
# IMPORTANT: transcripts (.jsonl) are NOT synced. They can exceed
# GitHub's 100 MB per-blob cap after a long debug session and would
# silently break pushes. Use claude-session-history.md + memory/*.md
# for the curated record; raw transcripts live only on local disk at
# ~/.claude/projects/<PROJECT_DIR>/*.jsonl (recover via `claude` directly).
#
# IMPORTANT: this script ONLY READS from ~/.claude/. Never write there;
# the live Claude Code process owns those paths.
#
# Environment overrides:
#   REPO           — path to this repo (default: parent of scripts/)
#   HOST_NAME      — host directory under hosts/ (default: hostname -s)
#   CC_PROJECT_DIR — Claude Code project dir (default: -home-$USER, which
#                    is what `cd ~ && claude ...` produces)
set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
HOST_NAME="${HOST_NAME:-$(hostname -s)}"
CC_PROJECT_DIR="${CC_PROJECT_DIR:--home-${USER}}"
SRC_CLAUDE_MEMORY="${SRC_CLAUDE_MEMORY:-$HOME/.claude/projects/${CC_PROJECT_DIR}/memory/}"
DST_CLAUDE_MEMORY="${REPO}/hosts/${HOST_NAME}/claude-code-memory/"

# Bail if nothing to sync — common on hosts where the user hasn't
# started a claude session yet (no project dir exists), or where the
# symlink hasn't been set up.
if [[ ! -e "${SRC_CLAUDE_MEMORY}" ]]; then
  echo "[sync-cc-history] ${SRC_CLAUDE_MEMORY} doesn't exist — skipping (claude never started from \$HOME on ${HOST_NAME}?)" >&2
  exit 0
fi

# Heartbeat marker — proves cron fired even when nothing changed
# (rsync of unchanged content + no git diff is the common case).
# `doctor.sh` reads this to distinguish "cron alive" from "cron dead".
mkdir -p "${HOME}/.hermes/logs"
date -u +%Y-%m-%dT%H:%M:%SZ > "${HOME}/.hermes/logs/sync-cc-history.heartbeat" 2>/dev/null || true

mkdir -p "${DST_CLAUDE_MEMORY}"

# Memory dir is typically a symlink; -L follows it to copy file contents,
# not the link. --delete propagates renames + retirements from upstream.
rsync -aL --delete \
  --include="*.md" \
  --exclude="*" \
  "${SRC_CLAUDE_MEMORY}" "${DST_CLAUDE_MEMORY}"

cd "${REPO}"

# Path-scoped stage: never touch other tracked paths the user is hand-editing.
git add "hosts/${HOST_NAME}/"

if git diff --cached --quiet; then
  exit 0
fi

git commit -m "sync: cc history snapshot ${HOST_NAME} $(date -u +%Y-%m-%dT%H:%MZ)" >/dev/null

if ! git push origin main 2>/dev/null; then
  echo "[sync-cc-history] push failed; will retry next cycle" >&2
  exit 0
fi
