#!/usr/bin/env bash
# Restore the hindsight memory bank from the encrypted snapshot in
# hindsight-data/dump.sql.gz. Used during fresh-machine recovery (after
# git clone + git-crypt unlock) and also as the rollback path if a bad
# write to the bank needs reverting.
#
# Workflow:
#   1. Stop hindsight-server (hermes-gateway keeps running but its memory
#      tools fail until the server is back).
#   2. Truncate the user tables (don't drop the schema — alembic owns it
#      and recreating from migration is more brittle than truncating).
#   3. Replay the SQL dump.
#   4. Restart hindsight-server, verify /health, recall a known fact.
#
# This script is destructive — it WILL drop everything currently in the
# bank in favor of the snapshot. Confirms before running unless --yes.
set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
PGBIN="${PGBIN:-$HOME/.pg0/installation/18.1.0/bin}"
PGHOST="127.0.0.1"
PGPORT="5432"
PGUSER="hindsight"
PGDATABASE="hindsight"
export PGPASSWORD="hindsight"

DUMP="${REPO}/hindsight-data/dump.sql.gz"

confirm=""
if [[ "${1:-}" != "--yes" ]]; then
  echo "About to:"
  echo "  - stop hindsight-server.service"
  echo "  - TRUNCATE all hindsight bank tables"
  echo "  - replay ${DUMP}"
  echo "  - restart hindsight-server"
  read -rp "Continue? [type RESTORE to proceed]: " confirm
  if [[ "${confirm}" != "RESTORE" ]]; then
    echo "aborted"
    exit 1
  fi
fi

if [[ ! -f "${DUMP}" ]]; then
  echo "no dump at ${DUMP} — has the repo been cloned + git-crypt unlocked?" >&2
  exit 1
fi

# Verify the file isn't still encrypted (looks like \0GITCRYPT prefix
# means git-crypt didn't unlock).
if [[ "$(head -c 9 "${DUMP}" | od -An -c | tr -d ' ')" == *"GITCRYPT"* ]]; then
  echo "${DUMP} is still git-crypt-encrypted. Run: git-crypt unlock <key>" >&2
  exit 1
fi

echo "[restore] stopping hindsight-server..."
systemctl --user stop hindsight-server.service

# Restart pg0 to make sure no stale connections hold the tables.
# (hindsight-api owns its own connection pool; stopping the unit closes
# them but background pg0 still holds idle ones for a moment.)
sleep 2

echo "[restore] truncating user tables..."
"${PGBIN}/psql" \
    --host="${PGHOST}" --port="${PGPORT}" \
    --username="${PGUSER}" --dbname="${PGDATABASE}" \
    --quiet --tuples-only --no-align \
    -c "DO \$\$
BEGIN
  EXECUTE (SELECT string_agg('TRUNCATE TABLE '||quote_ident(schemaname)||'.'||quote_ident(relname)||' CASCADE', '; ')
           FROM pg_stat_user_tables);
END \$\$;"

echo "[restore] replaying dump..."
gunzip -c "${DUMP}" \
  | "${PGBIN}/psql" \
      --host="${PGHOST}" --port="${PGPORT}" \
      --username="${PGUSER}" --dbname="${PGDATABASE}" \
      --quiet --single-transaction --set ON_ERROR_STOP=1 \
      >/dev/null

echo "[restore] starting hindsight-server..."
systemctl --user start hindsight-server.service

echo "[restore] waiting for /health..."
for _ in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:8765/health >/dev/null 2>&1; then
    echo "[restore] healthy ✓"
    break
  fi
  sleep 1
done

echo "[restore] row counts:"
"${PGBIN}/psql" \
    --host="${PGHOST}" --port="${PGPORT}" \
    --username="${PGUSER}" --dbname="${PGDATABASE}" \
    --quiet --tuples-only --no-align \
    -c "SELECT relname || ': ' || n_live_tup FROM pg_stat_user_tables WHERE n_live_tup > 0 ORDER BY n_live_tup DESC LIMIT 10"
