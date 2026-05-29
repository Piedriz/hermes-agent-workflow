#!/usr/bin/env bash
# Daily backup of the hindsight memory bank.
#
# Strategy: per-table data dumps under hindsight-data/<table>.sql, plus
# byte-rotation chunked layout for tables that exceed GitHub's 100 MB
# per-blob cap (memory_units today; memory_links eventually).
#
# Why per-table:
# - The bank's largest table (memory_units) exceeds 100 MB unchunked
#   for any non-trivial usage. A single dump.sql would hit GitHub's
#   hard blob cap and the push would fail.
# - Per-table layout gives a natural unit of chunking for the bulk
#   tables while keeping small tables as plain single files.
#
# Chunked layout for a bulk table T:
#
#   hindsight-data/T/
#     .rotation.json          # frozen-chunk PK boundaries
#     0001.sql                # frozen INSERTs, PKs ≤ max_pk_1
#     0002.sql                # frozen INSERTs, PKs ∈ (max_pk_1, max_pk_2]
#     NNNN.sql                # CURRENT chunk — PKs > last frozen
#
# Past chunks stay byte-identical across runs unless rows in their
# range actually changed. Pack-delta keeps daily growth tiny.
# When the current chunk exceeds the 80 MB rotation target, the next
# run freezes its highest PK as a new boundary and opens a fresh
# current chunk. See scripts/lib/chunked-table-dump.py for the
# rotation logic.
#
# Why per-table data-only-sorted-plaintext:
# - --data-only: skips schema; we re-create that from hindsight-api-slim's
#   alembic migrations on restore.
# - --column-inserts: one INSERT per row, diffable line-by-line.
# - sorted: lex-sorted INSERTs are deterministic across runs (pg_dump's
#   own order is heap-page-dependent).
# - NOT gzipped: gzip rearranges its bitstream when even a few rows
#   change, defeating git's pack-delta compression. Plaintext sorted
#   SQL is the right input for pack-delta + zlib; per-day cost in
#   pack collapses to ~the changed-rows size. git-crypt is deterministic
#   per path so encryption doesn't break delta either.
#
# Restore: scripts/restore-hindsight-bank.sh — stops server, drops
# the bank, re-runs alembic migrations, `cat` chunks into psql, restarts.
set -euo pipefail

# Cron runs without the user's systemd session env vars; `systemctl
# --user is-active` fails with "Failed to connect to bus" and the
# server-up probe trips even when the service IS running. Set
# XDG_RUNTIME_DIR so the user-bus probe works under cron.
: "${XDG_RUNTIME_DIR:=/run/user/$(id -u)}"
export XDG_RUNTIME_DIR

REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
PGBIN="${PGBIN:-$HOME/.pg0/installation/18.1.0/bin}"
PGHOST="${PGHOST:-127.0.0.1}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-hindsight}"
PGDATABASE="${PGDATABASE:-hindsight}"
# Password is set by pg0 at install; readable from pg_hba.conf, no real
# secret. The data IS the secret — and the dump itself is encrypted.
export PGPASSWORD="${PGPASSWORD:-hindsight}"

OUT_DIR="${REPO}/hindsight-data"

mkdir -p "${OUT_DIR}"

# Sanity: server up?
if ! systemctl --user is-active hindsight-server.service >/dev/null 2>&1; then
  echo "[sync-hindsight] hindsight-server.service not active — skipping" >&2
  exit 0
fi

# Each bulk-table entry is "table:pk_column". `pk_column` is the column
# the script buckets + orders by. For tables with a single `id`, that's
# the PK. For join tables (memory_links — composite key
# (from_unit_id, to_unit_id, link_type)) use whichever column has the
# widest value distribution; the chunked layout doesn't require strict
# primary-key semantics, just a stable bucket key.
declare -a bulk_tables=(
  "memory_units:id"
  "memory_links:from_unit_id"
)
declare -a small_tables=(
  banks
  documents
  entities
  unit_entities
  entity_cooccurrences
  chunks
  async_operations
  alembic_version
)

# --- Bulk tables: chunked layout via the Python helper -------------------
for entry in "${bulk_tables[@]}"; do
  tbl="${entry%%:*}"
  pkcol="${entry##*:}"
  python3 "${REPO}/scripts/lib/chunked-table-dump.py" \
      --psql-host "${PGHOST}" --psql-port "${PGPORT}" \
      --psql-user "${PGUSER}" --psql-database "${PGDATABASE}" \
      --pg-dump-path "${PGBIN}/pg_dump" \
      --table "public.${tbl}" \
      --pk-column "${pkcol}" \
      --out-dir "${OUT_DIR}/${tbl}"
done

# --- Small tables: flat data-only dumps ----------------------------------
for tbl in "${small_tables[@]}"; do
  tmp="${OUT_DIR}/.${tbl}.sql.tmp"
  out="${OUT_DIR}/${tbl}.sql"
  "${PGBIN}/pg_dump" \
      --host="${PGHOST}" --port="${PGPORT}" \
      --username="${PGUSER}" --dbname="${PGDATABASE}" \
      --data-only --column-inserts \
      --table="public.${tbl}" \
    | awk -v prefix="INSERT INTO public.${tbl} " \
        'index($0, prefix) == 1 { print }' \
    | LC_ALL=C sort \
    > "${tmp}"
  mv "${tmp}" "${out}"
done

# --- Drop the legacy monolithic dump on first run of this version. -------
# Idempotent: a fresh repo without the file just falls through.
if [[ -f "${OUT_DIR}/dump.sql" ]]; then
  git -C "${REPO}" rm --quiet --cached "hindsight-data/dump.sql" 2>/dev/null || true
  rm -f "${OUT_DIR}/dump.sql"
fi
if [[ -f "${OUT_DIR}/dump.sql.gz" ]]; then
  git -C "${REPO}" rm --quiet --cached "hindsight-data/dump.sql.gz" 2>/dev/null || true
  rm -f "${OUT_DIR}/dump.sql.gz"
fi

# Empty SQL files and git-crypt do not make good long-lived blobs: the
# encrypted object has a header, but checkout smudges it back to a 0-byte
# working-tree file, which can leave the repo looking dirty forever.
# Treat absent table files as "empty table" and only version dumps that
# contain rows.
find "${OUT_DIR}" -type f -name '*.sql' -size 0 -delete
find "${OUT_DIR}" -type d -empty -delete

# --- Commit + push only if anything changed ------------------------------
cd "${REPO}"
git add hindsight-data/

if git diff --cached --quiet; then
  echo "[sync-hindsight] no change — skipping commit"
  exit 0
fi

# Aggregate byte count across all dumped files (for the commit msg).
total_bytes=$(find "${OUT_DIR}" -type f \
    \( -name '*.sql' -o -name '.rotation.json' \) \
    -printf '%s\n' | awk '{s+=$1} END{print s+0}')

git commit -m "hindsight-bank: daily snapshot $(date -u +%Y-%m-%dT%H:%MZ) (${total_bytes}b)" >/dev/null

if ! git push origin main 2>/dev/null; then
  echo "[sync-hindsight] push failed; will retry next cycle" >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# To enable daily cron at 03:33 (off the 15-min sync grid):
#
#   crontab -e
#   33 3 * * * <REPO>/scripts/sync-hindsight-bank.sh \
#     >> <HERMES>/logs/sync-hindsight-bank.log 2>&1
# ---------------------------------------------------------------------------
