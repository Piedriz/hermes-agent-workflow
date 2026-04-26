#!/usr/bin/env bash
# hermes-agent-workflow / scripts / doctor.sh
#
# Health check + self-heal for a hermes install.
# Idempotent, cron-safe, silent-when-healthy (suitable for frequent scheduling).
#
# Fixes (non-destructive):
#   - Re-establishes any broken symlink into this repo.
#
# Warns (no auto-fix):
#   - Missing expected service / bridge / daemon.
#   - Disk free below threshold.
#   - Config invariants broken (e.g. memory.provider unset, WhatsApp
#     allowlist empty when a group is allowed).
#
# Cron (substitute your own paths):
#   */10 * * * * <REPO>/scripts/doctor.sh >> <HERMES>/logs/doctor.log 2>&1
#
# Or run manually: <REPO>/scripts/doctor.sh
#
# Environment overrides:
#   REPO       — path to this repo (default: parent of scripts/)
#   HERMES     — path to ~/.hermes (default: $HOME/.hermes)
#   HERMES_BIN — path to hermes CLI (default: $HOME/.local/bin/hermes)
#   HOST_NAME  — host directory under hosts/ (default: example-host)
#
# Exit codes:
#   0 — all healthy (or fixed in place)
#   1 — warnings surfaced (see output)
#   2 — fix attempted but failed

set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
HERMES="${HERMES:-$HOME/.hermes}"
HERMES_BIN="${HERMES_BIN:-$HOME/.local/bin/hermes}"
HOST_NAME="${HOST_NAME:-example-host}"

# Accumulators so we can summarize at the end.
ISSUES=()   # warnings / things to surface
FIXED=()    # things this run self-healed

# ── 1. Symlink integrity ──────────────────────────────────────────────
# Hermes's atomic-write commands (hermes config set, /sethome, hermes
# memory setup) replace the target file, which breaks symlinks. Re-
# establish the symlink so the next gateway restart reads from the
# canonical path.
check_symlink() {
  local live="$1"
  local target="$2"
  local label="$3"
  if [[ -L "${live}" ]]; then return 0; fi
  if [[ ! -e "${live}" ]]; then
    ISSUES+=("missing: ${label} at ${live}")
    return 0
  fi
  echo "[doctor] ${label}: symlink broken, repairing (${live} → ${target})"
  # If target differs from the live file, prefer live (it's what
  # hermes just wrote). Overwrite repo copy first.
  cp "${live}" "${target}"
  rm "${live}"
  ln -s "${target}" "${live}"
  FIXED+=("symlink: ${label}")
}

check_symlink "${HERMES}/config.yaml"             "${REPO}/hermes.config.yaml"       "hermes config"
check_symlink "${HERMES}/AGENTS.md"               "${REPO}/AGENTS.md"                "AGENTS.md"
check_symlink "${HERMES}/SOUL.md"                 "${REPO}/SOUL.md"                  "SOUL.md"
check_symlink "${HERMES}/hindsight/config.json"   "${REPO}/hindsight.config.json"    "hindsight config"
# channel_directory.json was previously symlinked here, but the gateway
# atomic-writes it every 5 min via os.replace, which nukes the symlink
# regardless of how often we re-heal. It's runtime cache (rebuilt on
# gateway start), not config — versioning it had no archival value and
# created continuous doctor.log churn. Now untracked and gitignored.
check_symlink "${HERMES}/gateway_voice_mode.json" "${REPO}/gateway_voice_mode.json"  "gateway_voice_mode.json"
# Directory symlinks — hermes tools occasionally replace these wholesale
# (atomic rename of a dir during cleanup); warn but don't auto-heal,
# since restoring a directory symlink without losing in-place edits
# requires manual review.
for dir_link in \
  "${HERMES}/memories" \
  "${HERMES}/skills" \
  "${HERMES}/cron" \
  "${HERMES}/hooks" \
  "${HERMES}/plugins"; do
  if [[ -e "${dir_link}" && ! -L "${dir_link}" ]]; then
    ISSUES+=("directory-symlink broken: ${dir_link} is a regular dir (manual review)")
  fi
done

# ── 2. Services ───────────────────────────────────────────────────────
check_service() {
  local name="$1"
  if ! systemctl --user is-active "${name}" >/dev/null 2>&1; then
    ISSUES+=("service not active: ${name}")
  fi
}
check_service hermes-gateway
check_service sidekick

# ── 3. WhatsApp bridge reachable (best-effort; daemon may be idle) ────
if systemctl --user is-active hermes-gateway >/dev/null 2>&1; then
  if ! curl -sf --max-time 2 http://localhost:3000/health >/dev/null 2>&1; then
    ISSUES+=("whatsapp bridge: /health not responding on :3000")
  fi
fi

# ── 4. Config invariants ──────────────────────────────────────────────
# If a WhatsApp group is allow-listed, the bridge allowlist must have
# at least one user — otherwise no message can ever reach the gateway.
if grep -q '^\s*-\s.*@g\.us' "${HERMES}/config.yaml" 2>/dev/null; then
  allowed=$(grep -E '^WHATSAPP_ALLOWED_USERS=' "${HERMES}/.env" 2>/dev/null | cut -d= -f2- | tr -d '"')
  if [[ -z "${allowed}" ]]; then
    ISSUES+=("whatsapp: group_allow_from set but WHATSAPP_ALLOWED_USERS is empty")
  fi
fi

# Terminal cwd resolves to a real directory? Hermes' shell tool spawns
# subprocesses with a cwd derived from MESSAGING_CWD (legacy env) or
# terminal.cwd (config.yaml). If that path doesn't exist, EVERY shell
# tool call dies with FileNotFoundError. The agent retries 3x per call,
# probes with several diagnostic commands, and the user sees nothing —
# their long prompt sits unanswered while the agent burns turns. We
# learned this 2026-04-25 when MESSAGING_CWD pointed at an old openclaw
# workspace dir that had been swept up during the openclaw spindown.
# Surface as a hard warning so the next deletion doesn't go silent.
cwd_value=$(grep -E '^MESSAGING_CWD=' "${HERMES}/.env" 2>/dev/null | cut -d= -f2- | tr -d '"' | head -1)
if [[ -z "${cwd_value}" ]]; then
  # Fall back to config.yaml terminal.cwd. Crude grep — handles the
  # default 2-space-indent layout. Full YAML parsing is overkill here.
  cwd_value=$(awk '/^terminal:/{f=1; next} f && /^[a-zA-Z]/{f=0} f && /^\s+cwd:/{print $2; exit}' "${HERMES}/config.yaml" 2>/dev/null | tr -d "'\"")
fi
if [[ -n "${cwd_value:-}" && "${cwd_value}" != "." ]]; then
  if [[ ! -d "${cwd_value}" ]]; then
    ISSUES+=("terminal.cwd: '${cwd_value}' does not exist — every shell tool call will fail with FileNotFoundError")
  fi
fi

# memory.provider set? (sanity — if user configured hindsight we want
# to notice if it got cleared accidentally).
provider=$(grep -E '^\s*provider:\s*' "${HERMES}/config.yaml" 2>/dev/null | head -1 | awk '{print $2}' | tr -d "'\"")
if [[ -n "${provider:-}" && "${provider}" == "hindsight" ]]; then
  # Ensure the LLM key for hindsight is present.
  if ! grep -q '^HINDSIGHT_LLM_API_KEY=' "${HERMES}/.env" 2>/dev/null; then
    ISSUES+=("hindsight: memory.provider=hindsight but HINDSIGHT_LLM_API_KEY missing from .env")
  fi

  # If hindsight is configured for local_external mode, the slim API
  # server needs to be running and answering /health. The systemd unit
  # is hindsight-server.service. Surface stalls as a doctor warning
  # rather than letting recall silently fail in hermes-gateway.
  hindsight_mode=$(python3 -c "import json; print(json.loads(open('${HERMES}/hindsight/config.json').read()).get('mode',''))" 2>/dev/null || echo "")
  if [[ "${hindsight_mode}" == "local_external" ]]; then
    if ! systemctl --user is-active hindsight-server.service >/dev/null 2>&1; then
      ISSUES+=("hindsight: mode=local_external but hindsight-server.service is not active")
    elif ! curl -fsS --max-time 3 http://127.0.0.1:8765/health >/dev/null 2>&1; then
      ISSUES+=("hindsight: hindsight-server.service active but /health not responding on 127.0.0.1:8765")
    fi
  fi
fi

# ── 5. Local hermes patches ───────────────────────────────────────────
# The WhatsApp sender-prefix patch lives on a local branch of the
# installed hermes-agent checkout (editable install). Warn if the
# marker line is missing — someone could have switched branches,
# force-reset main, or an upstream upgrade could have relocated the
# code we patched. Do NOT auto-reapply; we want a human review.
WA_PATCH_FILE="${HERMES}/hermes-agent/gateway/platforms/whatsapp.py"
if [[ -f "${WA_PATCH_FILE}" ]]; then
  if ! grep -q 'if is_group and body:' "${WA_PATCH_FILE}" 2>/dev/null; then
    ISSUES+=("hermes: whatsapp sender-prefix patch missing from ${WA_PATCH_FILE} (local/whatsapp-sender-prefix branch dropped?)")
  fi
fi

# Companion patch in the WhatsApp bridge: the fromMe+isGroup early-bail
# was removed so the owner can @mention the bot in their own groups.
# Marker = the fixup block starting with "if (!isGroup) {" inside the
# fromMe handler. If upstream ever rewrites the fromMe path, this grep
# will miss and the warning will fire — which is what we want.
WA_BRIDGE_FILE="${HERMES}/hermes-agent/scripts/whatsapp-bridge/bridge.js"
if [[ -f "${WA_BRIDGE_FILE}" ]]; then
  if ! grep -q 'never process status broadcasts' "${WA_BRIDGE_FILE}" 2>/dev/null; then
    ISSUES+=("hermes: whatsapp-bridge fromMe+isGroup patch missing from ${WA_BRIDGE_FILE} (local/whatsapp-sender-prefix branch dropped?)")
  fi
fi

# ── 5b. CC sync freshness ─────────────────────────────────────────────
# sync-cc-history.sh runs every 15 min via cron, committing snapshots
# with a "sync: cc history snapshot ..." subject. If no such commit has
# landed in the last 30 min AND the MEMORY.md marker is missing, the cron
# is silently failing — surface as a warning. (We use commit time rather
# than file mtime because rsync preserves source mtime, so dest files
# don't get touched on no-op reconciliations.)
CC_MEMORY_MARKER="${REPO}/hosts/${HOST_NAME}/claude-code-memory/MEMORY.md"
if [[ ! -f "${CC_MEMORY_MARKER}" ]]; then
  ISSUES+=("cc-sync: ${CC_MEMORY_MARKER} missing (sync-cc-history.sh has never run?)")
else
  last_sync_epoch=$(git -C "${REPO}" log -1 --since='30 minutes ago' --format=%ct \
    --grep='^sync: cc history snapshot' 2>/dev/null || true)
  if [[ -z "${last_sync_epoch}" ]]; then
    # Look up how stale the most recent matching commit actually is, for
    # a more useful warning message.
    most_recent=$(git -C "${REPO}" log -1 --format=%ct \
      --grep='^sync: cc history snapshot' 2>/dev/null || echo "0")
    if [[ "${most_recent}" == "0" ]]; then
      ISSUES+=("cc-sync: no 'sync: cc history snapshot' commit ever found in ${REPO}")
    else
      age_min=$(( ( $(date +%s) - most_recent ) / 60 ))
      ISSUES+=("cc-sync: last snapshot commit was ${age_min}min ago (>30min — sync-cc-history.sh cron stalled?)")
    fi
  fi
fi

# ── 6. Disk ───────────────────────────────────────────────────────────
# Threshold: warn under 2GB free. Hindsight data grows over time +
# hermes occasionally compresses state.db. Early warning helps.
free_mb=$(df -m "${HERMES}" | awk 'NR==2 {print $4}')
if (( free_mb < 2048 )); then
  ISSUES+=("disk: only ${free_mb}MB free on ${HERMES} filesystem (threshold: 2048MB)")
fi

# ── 7. Report ─────────────────────────────────────────────────────────
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

if [[ ${#FIXED[@]} -eq 0 && ${#ISSUES[@]} -eq 0 ]]; then
  # Silent healthy run — cron-friendly (no log bloat).
  exit 0
fi

echo "=== [doctor] ${now} ==="
if [[ ${#FIXED[@]} -gt 0 ]]; then
  echo "fixed:"
  printf '  • %s\n' "${FIXED[@]}"
fi
if [[ ${#ISSUES[@]} -gt 0 ]]; then
  echo "issues:"
  printf '  • %s\n' "${ISSUES[@]}"
  exit 1
fi
exit 0
