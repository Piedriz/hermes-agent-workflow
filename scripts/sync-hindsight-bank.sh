#!/usr/bin/env bash
# Daily backup of the hindsight memory bank.
#
# Strategy: pg_dump against the pg0 embedded postgres (hindsight-server.service),
# data-only, one INSERT per row, sorted, gzipped. Output gets encrypted at rest
# via git-crypt (.gitattributes pattern hindsight-data/** matches).
#
# Why data-only-sorted-and-compressed:
# - --data-only: skips schema; we re-create that from hindsight-api-slim's
#   alembic migrations on restore. The schema migrates over time; pinning
#   it would create restore conflicts with future server versions.
# - --column-inserts: one INSERT per row instead of multi-row COPY blocks.
#   Diffable line-by-line.
# - sorted: pg_dump's row order is non-deterministic (postgres chooses
#   based on heap pages), which would defeat git delta compression even
#   when content is unchanged. Sorting after-the-fact makes successive
#   identical dumps produce zero git diff.
#
# Why daily, not 15-min:
# - The bank changes on the order of memories/hour, not memories/15min.
# - Each dump is a full snapshot (pg_dump has no incremental mode).
# - 15-min commits would inflate the encrypted blob churn for no recovery
#   benefit. Daily gives ~year-long history at sane repo size.
#
# Restore: scripts/restore-hindsight-bank.sh handles the inverse — stops
# the server, drops the bank, replays the SQL, restarts the server.
set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
PGBIN="${PGBIN:-$HOME/.pg0/installation/18.1.0/bin}"
PGHOST="127.0.0.1"
PGPORT="5432"
PGUSER="hindsight"
PGDATABASE="hindsight"
# Password is set by pg0 at install; readable from pg_hba.conf, no real
# secret. The data IS the secret — and the dump itself is encrypted.
export PGPASSWORD="hindsight"

OUT_DIR="${REPO}/hindsight-data"
OUT_FILE="${OUT_DIR}/dump.sql.gz"
TMP_FILE="${OUT_DIR}/.dump.sql.gz.tmp"

mkdir -p "${OUT_DIR}"

# Sanity: server up?
if ! systemctl --user is-active hindsight-server.service >/dev/null 2>&1; then
  echo "[sync-hindsight] hindsight-server.service not active — skipping" >&2
  exit 0
fi

# Sort lines that look like INSERT/SET/SELECT — leave the schema-comment
# header lines at the start untouched. pg_dump's --data-only output is
# essentially: a few SET/SELECT setup lines, then INSERT statements per
# table. Sorting INSERTs lexically gives stable order across runs.
"${PGBIN}/pg_dump" \
    --host="${PGHOST}" --port="${PGPORT}" \
    --username="${PGUSER}" --dbname="${PGDATABASE}" \
    --data-only --column-inserts \
  | LC_ALL=C sort \
  | gzip -9 \
  > "${TMP_FILE}"

# Atomic replace so a concurrent reader never sees a half-written file.
mv "${TMP_FILE}" "${OUT_FILE}"

# Commit + push only if the dump bytes changed. git-crypt's clean filter
# encrypts on-stage, so the actual repo-side blob is encrypted.
cd "${REPO}"
git add hindsight-data/dump.sql.gz

if git diff --cached --quiet; then
  echo "[sync-hindsight] no change — skipping commit"
  exit 0
fi

bytes=$(wc -c < "${OUT_FILE}")
git commit -m "hindsight-bank: daily snapshot $(date -u +%Y-%m-%dT%H:%MZ) (${bytes}b)" >/dev/null

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
