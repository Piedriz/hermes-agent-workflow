#!/usr/bin/env bash
# Restore ~/.hermes/state.db from the dump in hermes-data/state.sql.
#
# Use case: bringing up a host as the new active. Replays sessions +
# messages from the active-host's last sync. FTS indexes are rebuilt
# on restore (cheaper to rebuild than to version).
#
# DESTRUCTIVE: replaces ${HOME}/.hermes/state.db. Requires hermes-gateway
# to be stopped (live writers would race with the replay). Refuses to
# run if gateway is active.
#
# Flags:
#   --yes             Skip the confirmation prompt.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DUMP="${REPO}/hermes-data/state.sql"
LIVE_DB="${HOME}/.hermes/state.db"
ASSUME_YES=0

for arg in "$@"; do
  case "$arg" in
    --yes) ASSUME_YES=1 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed 's/^# \?//;$d'; exit 0 ;;
    *) printf 'unknown flag: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

# UI helpers
if [[ -t 1 ]]; then c_y=$'\033[33m'; c_g=$'\033[32m'; c_r=$'\033[31m'; c_0=$'\033[0m'
else c_y=''; c_g=''; c_r=''; c_0=''; fi
ok()   { printf '%s✓%s %s\n' "$c_g" "$c_0" "$*"; }
warn() { printf '%s!%s %s\n' "$c_y" "$c_0" "$*"; }
die()  { printf '%s✗%s %s\n' "$c_r" "$c_0" "$*" >&2; exit 1; }
say()  { printf '→ %s\n' "$*"; }

# --- Pre-flight ---------------------------------------------------------
if [[ ! -f "${DUMP}" ]]; then
  die "no dump at ${DUMP}.
     Run scripts/sync-hermes-state.sh on the previous active host first
     (or unlock git-crypt: git-crypt unlock <key>)."
fi

# Refuse if gateway is running (would race the replay).
if systemctl --user is-active --quiet hermes-gateway.service; then
  die "hermes-gateway.service is active. Stop it before restoring:
       systemctl --user stop hermes-gateway.service"
fi

# --- Confirm ------------------------------------------------------------
if (( ! ASSUME_YES )); then
  cat <<EOF
${c_y}This will REPLACE${c_0} ${LIVE_DB} with the contents of:
  ${DUMP}  ($(du -h "${DUMP}" | cut -f1))

Existing sessions and messages on this host will be wiped. The dump's
sessions and messages take their place. FTS indexes will be rebuilt
from the new content.

Continue? [y/N]
EOF
  read -r reply
  if [[ "${reply}" != "y" && "${reply}" != "Y" ]]; then
    die "aborted"
  fi
fi

# --- Backup the existing DB before overwriting --------------------------
if [[ -f "${LIVE_DB}" ]]; then
  BACKUP="${LIVE_DB}.pre-restore.$(date +%Y%m%d-%H%M%S)"
  cp -a "${LIVE_DB}" "${BACKUP}"
  ok "backed up existing state.db to ${BACKUP}"
fi

# --- Wipe + replay ------------------------------------------------------
say "wiping existing state.db..."
rm -f "${LIVE_DB}" "${LIVE_DB}-shm" "${LIVE_DB}-wal"

say "replaying ${DUMP}..."
sqlite3 "${LIVE_DB}" < "${DUMP}"
ok "data tables loaded"

# --- Rebuild FTS indexes ------------------------------------------------
# The dump skipped messages_fts* (derivable). The FTS tables on this
# schema are CONTENTLESS standalone fts5 (no content='messages' link),
# so they don't auto-rebuild from messages — we have to populate them
# manually from the messages.content column. rowid is aligned with
# messages.id so the app's existing FTS lookup paths keep working.
say "rebuilding FTS indexes..."
sqlite3 "${LIVE_DB}" <<'SQL'
-- Drop any FTS tables left from a prior partial restore (defensive).
DROP TABLE IF EXISTS messages_fts;
DROP TABLE IF EXISTS messages_fts_trigram;

-- Standard FTS5 (token-based) — column is 'content'
CREATE VIRTUAL TABLE messages_fts USING fts5(content);

-- Trigram FTS5 (substring-search support)
CREATE VIRTUAL TABLE messages_fts_trigram USING fts5(content, tokenize='trigram');

-- Populate from messages (NULL content rows are tool_call frames; skip).
INSERT INTO messages_fts(rowid, content)
  SELECT id, content FROM messages WHERE content IS NOT NULL;
INSERT INTO messages_fts_trigram(rowid, content)
  SELECT id, content FROM messages WHERE content IS NOT NULL;
SQL

ok "restore complete"
echo
echo "Sanity:"
sqlite3 "${LIVE_DB}" "SELECT
    (SELECT count(*) FROM sessions) || ' sessions, ' ||
    (SELECT count(*) FROM messages) || ' messages';"
echo
echo "Next: start gateway (systemctl --user start hermes-gateway.service)"
