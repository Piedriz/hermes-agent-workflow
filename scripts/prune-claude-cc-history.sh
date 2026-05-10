#!/usr/bin/env bash
# Prune Claude Code .jsonl transcripts on local disk.
#
# WHY: Claude Code writes one .jsonl per session under
#   ~/.claude/projects/<encoded-cwd>/*.jsonl
# These are NOT git-synced (they exceed GitHub's 100MB blob cap on
# longer sessions — a single active session can be 8MB+). They
# accumulate unbounded on disk. Keep them on the active host so
# verbatim session lookup works for recent work, but reap stale ones.
#
# Retention: keep last 30 days as-is, drop everything older. Refine
# to dilated retention (e.g. last 7 daily / 8-30 weekly / 30+ monthly)
# if 30 days proves too aggressive in practice.
#
# Idempotent + safe: only deletes regular files in the per-project
# `.jsonl` listing. Never recurses, never touches anything under
# hosts/<host>/claude-code-memory/ (the curated memory dir is small
# and lives in the repo).
#
# Cron-safe: writes a heartbeat to ~/.hermes/logs/ so doctor.sh / a
# future health check can see it firing.
#
# Usage:
#   scripts/prune-claude-cc-history.sh         # actually prune
#   scripts/prune-claude-cc-history.sh --dry   # show what would be deleted
set -euo pipefail

DAYS_TO_KEEP=30
LOG_DIR="${HOME}/.hermes/logs"
HEARTBEAT="${LOG_DIR}/prune-claude-cc-history.heartbeat"

DRY_RUN=0
if [[ "${1:-}" == "--dry" || "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi

# Claude Code encodes the project cwd by replacing '/' with '-'. We
# cover two encodings: a session launched from $HOME (covers the
# claude-remote default) and one launched from this repo's checkout.
# We don't know the repo's path at script-write time, so derive it
# from the script location — that's the public-template equivalent
# of the private fork's hardcoded paths.
encoded_home="$(echo "${HOME}" | tr '/' '-')"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
encoded_repo="$(echo "${REPO_DIR}" | tr '/' '-')"

TARGETS=(
  "${HOME}/.claude/projects/${encoded_home}/"
  "${HOME}/.claude/projects/${encoded_repo}/"
)

mkdir -p "${LOG_DIR}"
date -u +%Y-%m-%dT%H:%M:%SZ > "${HEARTBEAT}" 2>/dev/null || true

total_kept=0
total_pruned=0
total_bytes_pruned=0

for dir in "${TARGETS[@]}"; do
  [[ -d "${dir}" ]] || continue

  while IFS= read -r -d '' f; do
    size=$(stat -c %s "${f}" 2>/dev/null || echo 0)
    if [[ "${DRY_RUN}" == "1" ]]; then
      echo "[dry-run] would prune: ${f} ($((size/1024)) KB)"
    else
      rm -f "${f}"
    fi
    total_pruned=$((total_pruned + 1))
    total_bytes_pruned=$((total_bytes_pruned + size))
  done < <(find "${dir}" -maxdepth 1 -type f -name '*.jsonl' -mtime "+${DAYS_TO_KEEP}" -print0 2>/dev/null)

  while IFS= read -r f; do
    total_kept=$((total_kept + 1))
  done < <(find "${dir}" -maxdepth 1 -type f -name '*.jsonl' -mtime "-${DAYS_TO_KEEP}" 2>/dev/null)
done

mb_pruned=$((total_bytes_pruned / 1024 / 1024))
verb="pruned"
[[ "${DRY_RUN}" == "1" ]] && verb="would prune"
echo "[prune-cc-history] kept ${total_kept} jsonl < ${DAYS_TO_KEEP}d, ${verb} ${total_pruned} jsonl ≥ ${DAYS_TO_KEEP}d (${mb_pruned} MB)"
