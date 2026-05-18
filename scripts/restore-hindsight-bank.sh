#!/usr/bin/env bash
# Restore the hindsight memory bank from the encrypted per-table dumps
# in hindsight-data/. Used during fresh-machine recovery (after git
# clone + git-crypt unlock) and as the rollback path if a bad write
# to the bank needs reverting.
#
# Layout consumed:
#   hindsight-data/<table>.sql              — small tables (single file)
#   hindsight-data/<table>/NNNN.sql         — chunked bulk tables
#   hindsight-data/<table>/.rotation.json   — chunk metadata (informational
#                                             here; restore just cats everything)
#
# Workflow:
#   1. Ensure hindsight-server.service is running (pg0 is embedded in the
#      api process — stopping the server kills pg0). We work against the
#      live server.
#   2. Truncate user tables. Filter pg_class by relkind='r' so we don't
#      try to TRUNCATE views or partitioned-table parents.
#   3. Concat the per-table dumps (file order = alpha order, so 0001.sql
#      → 0002.sql → … for chunked tables) and replay with
#      session_replication_role=replica so FK triggers don't fire —
#      sync-hindsight-bank.sh produces alphabetically sorted INSERTs (for
#      git-diff stability), which doesn't respect FK ordering and would
#      otherwise fail.
#   4. Verify /health and print row counts.
#
# This script is destructive — it WILL drop everything currently in the
# bank in favor of the snapshot. Confirms before running unless --yes.
#
# Prereqs:
#   - hindsight-server.service is started (we'll start it if not, since
#     pg0 needs to be live).
#   - The hindsight role must have superuser bit (set by pg0's initdb).
#     If it doesn't, session_replication_role won't take effect.
set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
PGBIN="${PGBIN:-$HOME/.pg0/installation/18.1.0/bin}"
PGHOST="${PGHOST:-127.0.0.1}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-hindsight}"
PGDATABASE="${PGDATABASE:-hindsight}"
export PGPASSWORD="${PGPASSWORD:-hindsight}"

DUMP_DIR="${REPO}/hindsight-data"

confirm=""
if [[ "${1:-}" != "--yes" ]]; then
  echo "About to:"
  echo "  - ensure hindsight-server.service is running (pg0 needs it)"
  echo "  - TRUNCATE all hindsight bank user tables"
  echo "  - replay per-table dumps from ${DUMP_DIR} with FK triggers disabled"
  read -rp "Continue? [type RESTORE to proceed]: " confirm
  if [[ "${confirm}" != "RESTORE" ]]; then
    echo "aborted"
    exit 1
  fi
fi

if [[ ! -d "${DUMP_DIR}" ]]; then
  echo "no dump dir at ${DUMP_DIR} — has the repo been cloned + git-crypt unlocked?" >&2
  exit 1
fi

# Verify the files aren't still encrypted (\0GITCRYPT prefix means git-crypt
# didn't unlock). Probe the smallest table file as a proxy.
probe=$(find "${DUMP_DIR}" -name '*.sql' -type f | head -1)
if [[ -z "${probe}" ]]; then
  echo "no .sql files in ${DUMP_DIR} — is the repo populated?" >&2
  exit 1
fi
if [[ "$(head -c 9 "${probe}" | od -An -c | tr -d ' ')" == *"GITCRYPT"* ]]; then
  echo "${probe} is still git-crypt-encrypted. Run: git-crypt unlock <key>" >&2
  exit 1
fi

# Ensure the server is running. pg0 is embedded; without the api process
# pg0 is dead and we can't connect.
if ! systemctl --user is-active --quiet hindsight-server.service 2>/dev/null; then
  echo "[restore] hindsight-server not running, starting..."
  systemctl --user start hindsight-server.service
fi
echo "[restore] waiting for /health..."
for _ in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:8765/health >/dev/null 2>&1; then break; fi
  sleep 1
done

echo "[restore] truncating user tables (relkind='r' only)..."
"${PGBIN}/psql" \
    --host="${PGHOST}" --port="${PGPORT}" \
    --username="${PGUSER}" --dbname="${PGDATABASE}" \
    --quiet -c "DO \$\$
DECLARE r record; sql text := '';
BEGIN
  FOR r IN
    SELECT n.nspname AS schemaname, c.relname
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind = 'r' AND n.nspname = 'public'
  LOOP
    sql := sql || 'TRUNCATE TABLE '||quote_ident(r.schemaname)||'.'||quote_ident(r.relname)||' CASCADE; ';
  END LOOP;
  IF sql <> '' THEN EXECUTE sql; END IF;
END \$\$;"

echo "[restore] replaying dumps (FK triggers disabled)..."
# Concat order:
#   1. small tables (single .sql files in ${DUMP_DIR})
#   2. chunked tables (subdirs with NNNN.sql files — alpha sort = id-range
#      order = chronological for our PK schemes).
#
# FK ordering doesn't matter under session_replication_role=replica, so
# we can pull in any reasonable order. Both find passes are alpha-sorted
# so the operation is deterministic.
( echo "SET session_replication_role = replica;"
  # Single-file table dumps (depth=1, ignore subdirs).
  find "${DUMP_DIR}" -maxdepth 1 -name '*.sql' -type f | LC_ALL=C sort | while read -r f; do
    cat "${f}"
  done
  # Chunked tables (depth=2, all .sql under each subdir).
  for subdir in "${DUMP_DIR}"/*/; do
    [[ -d "${subdir}" ]] || continue
    find "${subdir}" -maxdepth 1 -name '*.sql' -type f | LC_ALL=C sort | while read -r f; do
      cat "${f}"
    done
  done
  echo "SET session_replication_role = origin;"
) | "${PGBIN}/psql" \
      --host="${PGHOST}" --port="${PGPORT}" \
      --username="${PGUSER}" --dbname="${PGDATABASE}" \
      --quiet --single-transaction --set ON_ERROR_STOP=1 \
      >/dev/null

# Restart so the api's connection pool re-connects to a clean state. The
# server's caches (schema, alembic_version) will refresh.
echo "[restore] restarting hindsight-server to refresh caches..."
systemctl --user restart hindsight-server.service
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
