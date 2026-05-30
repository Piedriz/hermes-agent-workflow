#!/usr/bin/env bash
# Daily backup of ~/.hermes/state.db (sessions + messages SSOT).
#
# Strategy: sqlite3 ".backup" for an atomic snapshot (safe while gateway
# is live and writing — uses online-backup API). Then a chunked layout
# under hermes-data/ that git-crypt encrypts via the `hermes-data/**`
# pattern in .gitattributes:
#
#   hermes-data/
#     schema.sql            # CREATE TABLE/INDEX for the 4 data tables
#     sessions.sql          # small full dump (ordered by rowid)
#     state_meta.sql        # small full dump
#     schema_version.sql    # small full dump
#     messages/
#       .rotation.json      # frozen-chunk id boundaries
#       0001.sql            # frozen INSERTs, id <= max_pk_1
#       NNNN.sql            # CURRENT chunk — id > last frozen
#
# Why chunked instead of one monolithic state.sql:
# - A monolithic state.sql is re-written in full daily, so every snapshot
#   re-commits the whole blob — git history accumulates it once per day.
#   messages is the bulk (chat history) and grows without bound.
# - Chunking by messages.id (monotonic AUTOINCREMENT) keeps frozen chunks
#   byte-identical across runs: new rows always land in the current chunk,
#   so pack-delta collapses daily cost to ~the new rows' size. See
#   scripts/lib/chunked-sqlite-dump.py for the rotation logic.
#
# Why text dumps instead of binary file copy:
# - Binary state.db is undiffable and re-commits in full daily.
# - Explicit-column INSERTs survive schema migrations and compress well.
#   FTS indexes (messages_fts*) are derivable — rebuilt on restore.
#
# NOT gzipped: gzip rearranges its bitstream when even a few rows change,
# defeating pack-delta. Plaintext SQL is the right input for git's
# compression pipeline; git-crypt is deterministic per path so encryption
# doesn't break delta either.
#
# Why daily, not 15-min:
# - State changes on the order of messages/hour, not messages/15min.
# - Each dump is a full snapshot (no incremental mode).
#
# Restore: scripts/restore-hermes-state.sh — stops gateway, drops the
# state.db, applies schema.sql, replays the data files, rebuilds FTS.
set -euo pipefail

# Cron runs with a minimal PATH (/usr/bin:/bin). Different hosts keep
# sqlite3 in different places (miniconda, a side-loaded build when the
# distro's packaged sqlite is too old for newer dump functions, brew, …).
# Put the known locations first, then resolve the binary once and use
# that path consistently. Tweak as needed for the host.
export PATH="${HOME}/.local/sqlite-3.50.2/bin:${HOME}/miniconda3/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"
SQLITE3="$(command -v sqlite3 || true)"
if [[ -z "${SQLITE3}" ]]; then
  echo "[sync-hermes-state] sqlite3 not found — install sqlite3 or add it to PATH" >&2
  exit 1
fi

REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
LIVE_DB="${HOME}/.hermes/state.db"
SNAPSHOT="/tmp/state.db.snapshot.$$"
OUT_DIR="${REPO}/hermes-data"

# --- Multi-host guard ---------------------------------------------------
# Only the active host writes the dump. Both hosts dumping = merge
# conflicts on push. See HANDOFF.md.
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
"${SQLITE3}" "${LIVE_DB}" ".backup ${SNAPSHOT}"

# --- 2. Schema dump (plaintext) -----------------------------------------
# CREATE TABLE/INDEX for the 4 data tables only. Skip messages_fts*
# (derivable, rebuilt on restore) and sqlite_* internal tables. Tables
# before indexes so the replay order is valid; ORDER BY makes it
# deterministic for byte-stable diffs.
mkdir -p "${OUT_DIR}"
"${SQLITE3}" "${SNAPSHOT}" <<'SQL' > "${OUT_DIR}/schema.sql"
.mode list
SELECT sql || ';'
FROM sqlite_master
WHERE sql IS NOT NULL
  AND name NOT LIKE 'sqlite_%'
  AND name NOT LIKE 'messages_fts%'
  AND tbl_name IN ('sessions','messages','schema_version','state_meta')
ORDER BY (type = 'index'), name;
SQL

# --- 3. Data dumps via the chunked helper -------------------------------
# messages is the bulk table — chunked by its INTEGER PRIMARY KEY so
# frozen chunks stay byte-identical day-over-day. The small tables get
# single flat dumps (ordered by rowid).
python3 "${REPO}/scripts/lib/chunked-sqlite-dump.py" \
    --db "${SNAPSHOT}" --table messages --pk-column id \
    --out-dir "${OUT_DIR}/messages"
for tbl in sessions state_meta schema_version; do
  python3 "${REPO}/scripts/lib/chunked-sqlite-dump.py" \
      --db "${SNAPSHOT}" --table "${tbl}" \
      --out-file "${OUT_DIR}/${tbl}.sql"
done

# --- 4. Heartbeat marker ------------------------------------------------
mkdir -p "${HOME}/.hermes/logs"
date -u +%Y-%m-%dT%H:%M:%SZ > "${HOME}/.hermes/logs/sync-hermes-state.heartbeat" 2>/dev/null || true

# --- 5. Drop the old monolithic state.sql (one-time on first run of this
#     version; subsequent runs are no-ops since the file is gone).
if [[ -f "${OUT_DIR}/state.sql" ]]; then
  git -C "${REPO}" rm --quiet --cached "hermes-data/state.sql" 2>/dev/null || true
  rm -f "${OUT_DIR}/state.sql"
fi

# --- 6. Commit + push if changed ---------------------------------------
cd "${REPO}"

# GitHub rejects blobs over 100 MiB. Guard so a broken rotation never
# creates an unpushable snapshot commit.
too_large=$(find "${OUT_DIR}" -type f \
    \( -name '*.sql' -o -name '.rotation.json' \) \
    -size +95M -printf '%p %s\n')
if [[ -n "${too_large}" ]]; then
  echo "[sync-hermes-state] refusing to commit oversized dump files:" >&2
  echo "${too_large}" >&2
  exit 1
fi

git add hermes-data/

if git diff --cached --quiet; then
  exit 0
fi

total_bytes=$(find "${OUT_DIR}" -type f \
    \( -name '*.sql' -o -name '.rotation.json' \) \
    -printf '%s\n' | awk '{s+=$1} END{print s+0}')

git commit -m "hermes-state: daily snapshot $(date -u +%Y-%m-%dT%H:%MZ) (${total_bytes}b)" >/dev/null

if ! git push origin main 2>/dev/null; then
  echo "[sync-hermes-state] push failed; will retry next cycle" >&2
  exit 0
fi
