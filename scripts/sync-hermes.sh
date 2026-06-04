#!/usr/bin/env bash
# Capture hermes runtime state that ISN'T already symlinked into this repo.
# Idempotent, cron-safe.
#
# Architecture: most user-editable files are symlinked live-to-repo so
# edits in VSCode land immediately and the agent reads through. This
# script handles the remaining snapshot-only items (systemd units,
# session transcripts).
#
# Symlinked (no action needed here):
#   ~/.hermes/config.yaml             → ${REPO}/hermes.config.yaml
#   ~/.hermes/AGENTS.md               → ${REPO}/AGENTS.md
#   ~/.hermes/SOUL.md                 → ${REPO}/SOUL.md
#   ~/.hermes/memories                → ${REPO}/memories
#   ~/.hermes/skills                  → ${REPO}/skills (whole tree — bundled + user-skills/)
#   ~/.hermes/cron, hooks, plugins    → ${REPO}/{cron,hooks,plugins}
#   ~/.hermes/hindsight/config.json   → ${REPO}/hindsight.config.json
#   ~/.hermes/gateway_voice_mode.json → ${REPO}/gateway_voice_mode.json
# (channel_directory.json is intentionally NOT versioned — runtime cache,
#  rebuilt every 5 min on gateway startup; gitignored.)
#
# Copied on each run:
#   ~/.config/systemd/user/hermes-{gateway,dashboard,hindsight-server}.service
#   hermes sessions export --session-id <uuid>  (api_server + cli)
#
# Hindsight bank backup is handled by a SEPARATE daily cron entry that
# runs `pg_dump` against the slim server's pg0 instance; see
# scripts/sync-hindsight-bank.sh. Kept apart from this 15-min sync because
# the dump is expensive (full snapshot, no incremental) and the memory
# bank changes on the order of writes/hour, not writes/15min.
#
# SQLite DBs (~/.hermes/state.db, response_store.db) are deliberately
# NOT copied — hermes holds live handles. Use `hermes sessions export`
# as the safe read path.
#
# No --delete on session exports: archive semantics. If a session is
# pruned upstream, we keep the archived copy here. Same pattern as
# openclaw-agent-private/scripts/sync-history.sh.
set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
HERMES="${HERMES:-$HOME/.hermes}"
SYSTEMD_SRC="${SYSTEMD_SRC:-$HOME/.config/systemd/user}"
HERMES_BIN="${HERMES_BIN:-$HOME/.local/bin/hermes}"

mkdir -p "${REPO}/systemd" "${REPO}/sessions"

# --- Multi-host guard ----------------------------------------------------
# Only the active host runs mutating syncs. ACTIVE_HOST sentinel at repo
# root names the host that owns writes. See HANDOFF.md for the model.
# Standby hosts exit silently so cron stays idempotent on both.
if [[ -f "${REPO}/ACTIVE_HOST" ]]; then
  active_host=$(grep -E '^active_host=' "${REPO}/ACTIVE_HOST" | head -1 | cut -d= -f2-)
  if [[ "${active_host}" != "$(hostname)" ]]; then
    mkdir -p "${HERMES}/logs"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) standby (active=${active_host:-<unset>})" \
      > "${HERMES}/logs/sync-hermes.standby" 2>/dev/null || true
    exit 0
  fi
fi
# Heartbeat marker
mkdir -p "${HERMES}/logs"
date -u +%Y-%m-%dT%H:%M:%SZ > "${HERMES}/logs/sync-hermes.heartbeat" 2>/dev/null || true

# Symlink-integrity checks live in scripts/doctor.sh, which runs on its
# own cron (every 10 min). Keeping snapshot + health concerns separate
# so this script stays minimal and predictable.

# --- Systemd units (copied — system files, not symlinked) ---------------
# `--copy-links` (-L) follows symlinks at the source. Without it, if
# the live unit at ${SYSTEMD_SRC} is a symlink BACK to ${REPO}/systemd
# (a perfectly reasonable manual setup so edits-via-repo land
# immediately in live), `rsync -a` would copy the symlink itself —
# producing a circular self-targeting symlink in the repo on the
# NEXT sync (2026-05-19 incident). -L makes the copy follow through
# the symlink and write the file content into the repo.
for unit in hermes-gateway.service hermes-dashboard.service; do
  if [[ -f "${SYSTEMD_SRC}/${unit}" ]]; then
    rsync -aL "${SYSTEMD_SRC}/${unit}" "${REPO}/systemd/${unit}"
  fi
done

# --- Session exports (api_server + cli) ----------------------------------
# `hermes sessions list` output format:
#   <preview>  <age>  <source>  <uuid>
# UUIDs are the last whitespace-separated token on each data row.
# We snapshot both api_server (voice/gateway) and cli sources.
export_session() {
  local source="$1"
  local out_dir="${REPO}/sessions/${source}"
  mkdir -p "${out_dir}"
  local list
  if ! list=$("${HERMES_BIN}" sessions list --source "${source}" --limit 500 2>/dev/null); then
    return 0
  fi
  # Strip header lines (any line without a UUID at end) and extract UUIDs.
  while IFS= read -r uuid; do
    [[ -z "${uuid}" ]] && continue
    local out="${out_dir}/${uuid}.jsonl"
    # Already exported and non-empty? Skip — sessions are append-only after close.
    # Re-export if file is missing or was zero-byte (previous failure).
    if [[ -s "${out}" ]]; then
      continue
    fi
    if ! "${HERMES_BIN}" sessions export --session-id "${uuid}" "${out}" >/dev/null 2>&1; then
      # Leave a zero-byte marker; next run will retry. Don't abort the whole sync.
      : >"${out}"
      echo "[sync-hermes] export failed for ${source}/${uuid}" >&2
    fi
  done < <(
    printf '%s\n' "${list}" \
      | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
      | sort -u
  )
}

export_session api_server
export_session cli

# --- Hindsight data backup ------------------------------------------------
# Now handled by scripts/sync-hindsight-bank.sh on a separate daily cron.
# (The old local_embedded path at ~/.hindsight/profiles/hermes/ is dead —
# we run hindsight-api-slim with pg0 embedded postgres at
# ~/.pg0/instances/hindsight/data/, dumped via pg_dump.)

# --- Commit + push -------------------------------------------------------
cd "${REPO}"

git add -A

if git diff --cached --quiet; then
  exit 0
fi

git commit -m "sync: snapshot $(date -u +%Y-%m-%dT%H:%MZ)" >/dev/null

if ! git push origin main 2>/dev/null; then
  echo "[sync-hermes] push failed; will retry next cycle" >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# To enable 15-minute cron sync:
#
#   crontab -e
#   */15 * * * * <REPO>/scripts/sync-hermes.sh >> <HERMES>/logs/sync-hermes.log 2>&1
# ---------------------------------------------------------------------------
