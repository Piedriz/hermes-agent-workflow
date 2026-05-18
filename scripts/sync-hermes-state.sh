#!/usr/bin/env bash
# Daily backup of ~/.hermes/state.db (sessions + messages SSOT).
#
# Strategy: sqlite3 ".backup" for an atomic snapshot (safe while gateway
# is live and writing — uses online-backup API). Then sqlite3 ".dump"
# of just the data tables (sessions, messages, schema_version, state_meta)
# to plaintext SQL. Output gets git-crypt-encrypted via the `hermes-data/**`
# pattern in .gitattributes.
#
# Why text-dump instead of binary file copy:
# - Binary state.db can be 30+ MB. Daily binary commits = many GB/year, undiffable.
# - Text dump of data tables only (no FTS indexes) = much smaller raw. Append-only
#   workload (chat history) means most rows stay byte-identical day-over-
#   day, and pack-delta + zlib compress successive snapshots to ~the new
#   content. FTS is rebuilt on restore.
# - Diffable encrypted content can be reviewed in PR if anything changes
#   unexpectedly.
#
# NOT gzipped: gzip rearranges its bitstream when even a few rows
# change, defeating pack-delta. Plaintext is the right input for git's
# compression pipeline; pack-delta + zlib already reach near-gzip ratios
# on plaintext SQL while preserving delta-ability across snapshots.
# git-crypt is deterministic per path so encryption doesn't break delta.
#
# Why daily, not 15-min:
# - State changes on the order of messages/hour, not messages/15min.
# - Each dump is a full snapshot (no incremental mode).
# - 15-min commits would inflate the encrypted blob churn for no recovery
#   benefit. Daily gives ~year-long history at sane repo size.
#
# Restore: scripts/restore-hermes-state.sh — stops gateway, drops the
# state.db, replays the SQL, rebuilds FTS, restarts.
set -euo pipefail

# Cron runs with a minimal PATH (typically /usr/bin:/bin), which often
# doesn't include the sqlite3 binary if it lives in miniconda /
# pyenv / brew. Add common locations so the script works under cron
# AND interactively. Tweak as needed for the host.
export PATH="${HOME}/miniconda3/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"

REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
LIVE_DB="${HOME}/.hermes/state.db"
SNAPSHOT="/tmp/state.db.snapshot.$$"
OUT_DIR="${REPO}/hermes-data"
OUT_FILE="${OUT_DIR}/state.sql"

# --- Multi-host guard ---------------------------------------------------
# Only the active host writes the dump. Both hosts dumping = merge
# conflicts on push. Multi-host concurrent operation is v2; v1 supports
# a single ACTIVE_HOST sentinel.
if [[ -f "${REPO}/ACTIVE_HOST" ]]; then
  active_host=$(grep -E '^active_host=' "${REPO}/ACTIVE_HOST" | head -1 | cut -d= -f2-)
  if [[ "${active_host}" != "$(hostname)" ]]; then
    mkdir -p "${HOME}/.hermes/logs"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) standby (active=${active_host:-<unset>})" \
      > "${HOME}/.hermes/logs/sync-hermes-state.standby" 2>/dev/null || true
    exit 0
  fi
fi

if [[ ! -f "${LIVE_DB}" ]]; then
  echo "[sync-hermes-state] ${LIVE_DB} doesn't exist — skipping" >&2
  exit 0
fi

trap 'rm -f "${SNAPSHOT}" "${SNAPSHOT}.dump"' EXIT

# --- 1. Atomic snapshot -------------------------------------------------
# sqlite3's online .backup API is the only safe way to copy a live DB.
# A naive `cp` would race with active writers and produce corruption.
sqlite3 "${LIVE_DB}" ".backup ${SNAPSHOT}"

# --- 2. Text dump of data tables (plaintext) -----------------------------
# Skip messages_fts* (derivable). Skip sqlite_* internal tables.
#
# Note on ordering: sqlite3 .dump emits CREATE TABLE / INSERT in insertion
# order (heap-page order, which for normal append-only workloads matches
# rowid). Day-over-day diffs are mostly clean appends; full sort isn't
# worth it because CREATE TABLE statements span multiple lines and a
# naive line-sort breaks them.
mkdir -p "${OUT_DIR}"
sqlite3 "${SNAPSHOT}" \
  ".dump sessions messages schema_version state_meta" \
  > "${OUT_FILE}"

# --- 3. Heartbeat marker ------------------------------------------------
mkdir -p "${HOME}/.hermes/logs"
date -u +%Y-%m-%dT%H:%M:%SZ > "${HOME}/.hermes/logs/sync-hermes-state.heartbeat" 2>/dev/null || true

# --- 4. Commit + push if changed ---------------------------------------
cd "${REPO}"
git add "${OUT_FILE}"

if git diff --cached --quiet; then
  exit 0
fi

bytes=$(stat -c %s "${OUT_FILE}")
git commit -m "hermes-state: daily snapshot $(date -u +%Y-%m-%dT%H:%MZ) (${bytes}b)" >/dev/null

if ! git push origin main 2>/dev/null; then
  echo "[sync-hermes-state] push failed; will retry next cycle" >&2
  exit 0
fi
