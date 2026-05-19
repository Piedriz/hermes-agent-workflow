#!/bin/bash
# Hindsight health watchdog. Polls /health and restarts
# hindsight-server.service when the embedded pg0 backend is
# unreachable. Installed as a systemd timer triggering every minute.
#
# History: pg0 (the embedded Postgres pinned to ~/.pg0/instances/
# hindsight/data) crashed silently on 2026-05-12 and the hindsight-api
# parent kept retrying but never re-launched it. ~5 days of agent
# memories were lost. This watchdog catches the same failure mode in
# under a minute and restarts the parent — which boots pg0 fresh via
# MemoryEngine.start_pg0() on init.
#
# Restart is gated to "real" unhealthy responses (the JSON contains
# "database":"error") to avoid restart loops during legitimate
# startup or transient hiccups. Logs every action with a timestamp
# so post-mortem traces show exactly when an auto-restart fired.

set -u

LOG=/tmp/hindsight-doctor.log
HEALTH_URL="http://127.0.0.1:8765/health"
SERVICE="hindsight-server.service"

# Cap log to last ~1000 lines so it doesn't grow unbounded over
# weeks. Rotate cheaply with tail-and-rewrite (no logrotate dep).
LOG_CAP_LINES=1000

log() {
  echo "[$(date '+%F %T')] $*" >> "$LOG"
  # In-place cap. Atomic enough for this scale (no concurrent writers).
  if [ -f "$LOG" ]; then
    n=$(wc -l < "$LOG" 2>/dev/null || echo 0)
    if [ "$n" -gt "$LOG_CAP_LINES" ]; then
      tail -n "$LOG_CAP_LINES" "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
    fi
  fi
}

# Curl with a tight timeout — Hindsight should answer /health in
# milliseconds; anything slower than 5s already counts as "unhealthy."
response=$(curl -sS --max-time 5 "$HEALTH_URL" 2>/dev/null)
status=$?

if [ "$status" -ne 0 ]; then
  log "curl failed (exit=$status) — service likely not listening; nudging restart"
  systemctl --user restart "$SERVICE"
  log "restart issued (curl-fail path)"
  exit 0
fi

# Parse the response. Healthy looks like:
#   {"status":"healthy","database":"connected"}
# Sick (post-pg0-crash) looks like:
#   {"status":"unhealthy","database":"error","error":"..."}
if echo "$response" | grep -q '"database":"connected"'; then
  # Heartbeat (low frequency). Comment out if log volume becomes a
  # concern — the watchdog logs the interesting events regardless.
  # log "ok: $response"
  exit 0
fi

# Anything else (database:"error", malformed JSON, status:"unhealthy",
# etc.) → log + restart. Avoids restart loops by capping at one
# restart per minute via systemd's timer cadence.
log "unhealthy response: $response"
systemctl --user restart "$SERVICE"
log "restart issued (health-error path)"
