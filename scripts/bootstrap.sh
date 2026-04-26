#!/usr/bin/env bash
# hermes-agent-workflow / scripts / bootstrap.sh
#
# First-run setup wizard for a fresh fork of hermes-agent-workflow.
# A new contributor clones the repo, opens Claude Code in it, and the
# AGENTS.md walkthrough invokes this script. It is idempotent — re-runs
# detect existing state and skip done work.
#
# WHY a wizard rather than a README:
#   The hermes+sidekick stack has 3 venvs, 3 systemd units, an .env
#   secrets file, a config-symlink layout, and a sidekick clone in a
#   sibling directory. A README would 90%-misfire for any given user;
#   a wizard prompts for the load-bearing values and silently chooses
#   sane defaults for the rest.
#
# WHY idempotent:
#   Tom will run this multiple times: once to bootstrap, once after he
#   learns about a new env var, once when he debugs a failing service.
#   Every step must check state first.
set -euo pipefail

# ── 0. Repo location + UI helpers ────────────────────────────────────
REPO="$(cd "$(dirname "$0")/.." && pwd)"

# ANSI escapes — avoid external tput dep so the script works in minimal
# shells (e.g. bare ssh into a Pi with no terminfo).
if [[ -t 1 ]]; then
  C_GREEN=$'\033[0;32m'; C_RED=$'\033[0;31m'; C_YELLOW=$'\033[0;33m'
  C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
  C_GREEN=""; C_RED=""; C_YELLOW=""; C_BOLD=""; C_RESET=""
fi

ok()    { printf '%s✓%s %s\n' "${C_GREEN}" "${C_RESET}" "$*"; }
warn()  { printf '%s!%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*"; }
fail()  { printf '%s✗%s %s\n' "${C_RED}" "${C_RESET}" "$*" >&2; exit 1; }
info()  { printf '%s→%s %s\n' "${C_BOLD}" "${C_RESET}" "$*"; }
section() { printf '\n%s== %s ==%s\n' "${C_BOLD}" "$*" "${C_RESET}"; }

# ── 1. Pre-flight ────────────────────────────────────────────────────
# Bail early on missing system deps. We do NOT try to install them —
# install paths differ per OS (apt/brew/dnf) and silent sudo is hostile.
section "Pre-flight"

need() {
  local cmd="$1" hint="$2"
  if command -v "${cmd}" >/dev/null 2>&1; then
    ok "${cmd} found ($(command -v "${cmd}"))"
  else
    fail "${cmd} not on PATH. Install hint: ${hint}"
  fi
}

need uv      "curl -LsSf https://astral.sh/uv/install.sh | sh"
need git     "apt install git  |  brew install git"
need ffmpeg  "apt install ffmpeg  |  brew install ffmpeg"

# python3.11+ check — uv would catch this later but a clear message now
# saves Tom 10 minutes of confusing tracebacks.
if ! command -v python3 >/dev/null 2>&1; then
  fail "python3 not on PATH. Install Python 3.11+ first."
fi
PY_VER="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
PY_MAJ="${PY_VER%.*}"; PY_MIN="${PY_VER#*.}"
if (( PY_MAJ < 3 || (PY_MAJ == 3 && PY_MIN < 11) )); then
  fail "python3 is ${PY_VER}, need >=3.11. Install Python 3.11+ (uv can manage one: uv python install 3.11)."
fi
ok "python3 ${PY_VER}"

# ── 2. Prompt for config ─────────────────────────────────────────────
# We persist answers as a side-effect of writing them into ~/.hermes/.env
# (secrets) and downstream files (host name → systemd unit names). On
# re-runs we detect those and skip the prompt — never re-ask for keys.
section "Configuration"

ENV_FILE_DEFAULT="${HOME}/.hermes/.env"
HERMES_HOME_DEFAULT="${HOME}/.hermes"
SIDEKICK_PATH_DEFAULT="${HOME}/code/sidekick"

prompt_default() {
  # prompt_default <var-name> <prompt-text> <default> [--required]
  local var="$1" text="$2" default="$3" required="${4:-}"
  local current="${!var:-}"
  if [[ -n "${current}" ]]; then
    ok "${var}=${current} (from environment)"
    return
  fi
  local answer
  if [[ -n "${default}" ]]; then
    read -r -p "  ${text} [${default}]: " answer
    answer="${answer:-${default}}"
  else
    read -r -p "  ${text}: " answer
  fi
  if [[ "${required}" == "--required" && -z "${answer}" ]]; then
    fail "${var} is required."
  fi
  printf -v "${var}" '%s' "${answer}"
  export "${var}"
}

prompt_secret() {
  # prompt_secret <var-name> <prompt-text> [--required]
  # Reads silently. Skipped if .env already has the key.
  local var="$1" text="$2" required="${3:-}"
  local env_file="${HERMES_HOME}/.env"
  if [[ -f "${env_file}" ]] && grep -qE "^${var}=" "${env_file}"; then
    ok "${var} found in ${env_file}, leaving as-is"
    printf -v "${var}" '%s' "__KEEP__"
    export "${var}"
    return
  fi
  local answer
  read -r -s -p "  ${text}: " answer; echo
  if [[ "${required}" == "--required" && -z "${answer}" ]]; then
    fail "${var} is required."
  fi
  printf -v "${var}" '%s' "${answer}"
  export "${var}"
}

# Non-secret prompts
prompt_default HOST_NAME      "host name (used for hosts/<host>/ + systemd units)" "$(hostname -s)"
prompt_default SIDEKICK_PATH  "sidekick clone path" "${SIDEKICK_PATH_DEFAULT}"
prompt_default HERMES_HOME    "hermes home directory" "${HERMES_HOME_DEFAULT}"
prompt_default AGENT_LAT      "agent latitude (for ambient weather widget, optional)" ""
prompt_default AGENT_LON      "agent longitude (for ambient weather widget, optional)" ""

# Make sure HERMES_HOME exists before we look in it for an existing .env.
mkdir -p "${HERMES_HOME}"

# Secret prompts — only ask if .env doesn't already have them
prompt_secret  DEEPGRAM_API_KEY    "Deepgram API key (for STT)"          --required
prompt_secret  OPENROUTER_API_KEY  "OpenRouter API key (for LLM access)" --required

# ── 3. Sidekick clone ────────────────────────────────────────────────
# The PWA + audio bridge live in a separate public repo. We clone as a
# sibling directory rather than as a submodule so Tom can pull updates
# independently of the workflow framework version.
section "Sidekick"

if [[ -d "${SIDEKICK_PATH}/.git" ]]; then
  ok "found existing sidekick at ${SIDEKICK_PATH}, skipping clone"
elif [[ -e "${SIDEKICK_PATH}" ]]; then
  fail "${SIDEKICK_PATH} exists but is not a git repo — refusing to clobber. Move it aside or pick a different SIDEKICK_PATH."
else
  info "cloning sidekick → ${SIDEKICK_PATH}"
  mkdir -p "$(dirname "${SIDEKICK_PATH}")"
  git clone https://github.com/jscholz/sidekick "${SIDEKICK_PATH}"
  ok "sidekick cloned"
fi

# ── 4. Config symlink layout ─────────────────────────────────────────
# The workflow repo IS the source of truth for config — ~/.hermes/ is a
# façade pointing back at versioned files in this repo. Mirrors the
# private-repo pattern. We never overwrite an existing config.yaml; if
# the user has one, we assume they know what they're doing.
section "Config layout"

link_template() {
  # link_template <repo-relative-template> <hermes-relative-target>
  local tmpl="${REPO}/$1" live="${HERMES_HOME}/$2"
  if [[ ! -e "${tmpl}" ]]; then
    # TODO(jscholz): the workflow repo doesn't have these template files
    # yet — they'll land alongside the repo skeleton. Skip silently for
    # v0 so the bootstrap still completes; a future doctor.sh check can
    # warn if they end up missing in a real install.
    warn "template missing in repo: $1 (skipping)"
    return
  fi
  if [[ -L "${live}" ]]; then
    ok "${live} already linked"
    return
  fi
  if [[ -e "${live}" ]]; then
    ok "${live} exists (user-owned), leaving as-is"
    return
  fi
  mkdir -p "$(dirname "${live}")"
  ln -s "${tmpl}" "${live}"
  ok "linked ${live} → ${tmpl}"
}

# TODO(jscholz): canonical template filenames — confirm these match the
# v0 hermes-agent-workflow skeleton. Defaults below mirror the private
# repo's hermes.config.yaml + AGENTS.md + SOUL.md layout.
link_template "example.config.yaml"        "config.yaml"
link_template "example.AGENTS.md"          "AGENTS.md"
link_template "example.SOUL.md"            "SOUL.md"
link_template "example.hindsight.config.json" "hindsight/config.json"

# ── 5. uv venvs ──────────────────────────────────────────────────────
# Three venvs, three install patterns. uv handles them all but each has
# its own quirk:
#   - hermes-agent: editable install from a local git clone of upstream
#                   (so apply-patches.sh has a real repo to mutate; a
#                   PyPI install would be unmodifiable).
#   - hindsight:    pip install hindsight-api-slim from PyPI.
#   - audio-bridge: requirements.txt in the sidekick repo.
section "Python environments"

ensure_venv() {
  # ensure_venv <venv-path> <pkg-or-empty> [requirements-file]
  local venv="$1" pkg="${2:-}" reqs="${3:-}"
  if [[ -x "${venv}/bin/python" ]]; then
    ok "venv exists at ${venv}"
  else
    info "creating venv ${venv}"
    uv venv "${venv}"
  fi
  if [[ -n "${pkg}" ]]; then
    info "installing ${pkg} into ${venv}"
    uv pip install --python "${venv}/bin/python" "${pkg}"
  fi
  if [[ -n "${reqs}" && -f "${reqs}" ]]; then
    info "installing ${reqs} into ${venv}"
    uv pip install --python "${venv}/bin/python" -r "${reqs}"
  fi
}

# hermes-agent: clone upstream, then editable-install. Done as discrete
# steps (clone + install) instead of via ensure_venv because the patch
# workflow (scripts/apply-patches.sh) needs a real git repo to mutate.
HERMES_AGENT_REPO="${HERMES_HOME}/hermes-agent"
HERMES_VENV="${HERMES_HOME}/hermes-venv"
HERMES_UPSTREAM_URL="https://github.com/NousResearch/hermes-agent.git"

if [[ -d "${HERMES_AGENT_REPO}/.git" ]]; then
  ok "hermes-agent clone exists at ${HERMES_AGENT_REPO}"
else
  info "cloning hermes-agent → ${HERMES_AGENT_REPO}"
  git clone "${HERMES_UPSTREAM_URL}" "${HERMES_AGENT_REPO}"
  ok "hermes-agent cloned"
fi

# Ensure `origin` points at NousResearch upstream — apply-patches.sh
# refuses to operate against an unknown remote.
EXISTING_ORIGIN="$(git -C "${HERMES_AGENT_REPO}" remote get-url origin 2>/dev/null || true)"
case "${EXISTING_ORIGIN}" in
  *NousResearch/hermes-agent*|*NousResearch/hermes-agent.git)
    ok "origin remote: ${EXISTING_ORIGIN}"
    ;;
  "")
    info "adding origin remote → ${HERMES_UPSTREAM_URL}"
    git -C "${HERMES_AGENT_REPO}" remote add origin "${HERMES_UPSTREAM_URL}"
    ;;
  *)
    warn "origin remote is ${EXISTING_ORIGIN} (not NousResearch upstream).
        Leaving as-is; apply-patches.sh will surface the mismatch if it
        matters. To force-update: git -C ${HERMES_AGENT_REPO} remote set-url origin ${HERMES_UPSTREAM_URL}"
    ;;
esac

# Editable install into the hermes venv.
if [[ -x "${HERMES_VENV}/bin/python" ]]; then
  ok "venv exists at ${HERMES_VENV}"
else
  info "creating venv ${HERMES_VENV}"
  uv venv "${HERMES_VENV}"
fi
info "installing ${HERMES_AGENT_REPO} (editable) into ${HERMES_VENV}"
uv pip install --python "${HERMES_VENV}/bin/python" -e "${HERMES_AGENT_REPO}"

# TODO(jscholz): hindsight package choice — hardcoded hindsight-api-slim
# for v0. If you want full hindsight (heavy: torch + embedders), swap
# the line below to 'hindsight-api[embedded-db]' or similar.
ensure_venv "${HERMES_HOME}/hindsight-venv" "hindsight-api-slim"

# Audio bridge: lives inside sidekick repo; uv venv created in-place.
AUDIO_BRIDGE_DIR="${SIDEKICK_PATH}/audio-bridge"
if [[ -d "${AUDIO_BRIDGE_DIR}" ]]; then
  if [[ -x "${AUDIO_BRIDGE_DIR}/.venv/bin/python" ]]; then
    ok "audio-bridge venv exists"
  else
    info "creating audio-bridge venv"
    (cd "${AUDIO_BRIDGE_DIR}" && uv venv && uv pip install -r requirements.txt)
  fi
else
  warn "audio-bridge dir not found at ${AUDIO_BRIDGE_DIR} — skipping"
fi

# ── 6. systemd user units ────────────────────────────────────────────
# Generate per-user units from templates by substituting placeholders.
# We deliberately don't enable --now here; smoke-test step starts them
# explicitly so failures surface immediately instead of getting buried
# in journalctl.
section "systemd user units"

SYSTEMD_DST="${HOME}/.config/systemd/user"
mkdir -p "${SYSTEMD_DST}"

render_unit() {
  # render_unit <repo-relative-template> <output-name>
  local tmpl="${REPO}/$1" dst="${SYSTEMD_DST}/$2"
  if [[ ! -f "${tmpl}" ]]; then
    # TODO(jscholz): repo skeleton needs systemd/*.service templates with
    # {{USER}}, {{HOME}}, {{HERMES_HOME}}, {{SIDEKICK_PATH}}, {{HOST_NAME}}
    # placeholders. Until those land, skip with a warning so re-running
    # doesn't fail the whole bootstrap.
    warn "systemd template missing: $1 (skipping)"
    return
  fi
  sed \
    -e "s|{{USER}}|${USER}|g" \
    -e "s|{{HOME}}|${HOME}|g" \
    -e "s|{{HERMES_HOME}}|${HERMES_HOME}|g" \
    -e "s|{{SIDEKICK_PATH}}|${SIDEKICK_PATH}|g" \
    -e "s|{{HOST_NAME}}|${HOST_NAME}|g" \
    "${tmpl}" > "${dst}.tmp"
  if cmp -s "${dst}.tmp" "${dst}" 2>/dev/null; then
    rm "${dst}.tmp"
    ok "${dst} unchanged"
  else
    mv "${dst}.tmp" "${dst}"
    ok "wrote ${dst}"
  fi
}

render_unit "systemd/hermes-gateway.service"   "hermes-gateway.service"
render_unit "systemd/hermes-dashboard.service" "hermes-dashboard.service"
render_unit "systemd/hindsight-server.service" "hindsight-server.service"
# Optional fourth unit — sidekick audio bridge. Lives in sidekick repo
# but Tom may want a workflow-managed copy too.
render_unit "systemd/sidekick-audio.service"   "sidekick-audio.service"

systemctl --user daemon-reload
ok "systemctl --user daemon-reload"

# ── 7. Secrets → .env ────────────────────────────────────────────────
# We append rather than overwrite — Tom may have other env vars in there
# from a prior run or manual edit. chmod 600 every time defensively.
section "Secrets"

ENV_FILE="${HERMES_HOME}/.env"
touch "${ENV_FILE}"
chmod 600 "${ENV_FILE}"

write_env() {
  # write_env <KEY> <VALUE>
  # Skips if value is the __KEEP__ sentinel (already in file).
  local key="$1" val="$2"
  [[ "${val}" == "__KEEP__" ]] && return
  [[ -z "${val}" ]] && return
  if grep -qE "^${key}=" "${ENV_FILE}"; then
    # Update in place (sed -i with delimiter '|' to tolerate '/' in values).
    local tmp="${ENV_FILE}.tmp"
    sed "s|^${key}=.*|${key}=${val}|" "${ENV_FILE}" > "${tmp}"
    mv "${tmp}" "${ENV_FILE}"
    chmod 600 "${ENV_FILE}"
  else
    printf '%s=%s\n' "${key}" "${val}" >> "${ENV_FILE}"
  fi
}

write_env DEEPGRAM_API_KEY    "${DEEPGRAM_API_KEY}"
write_env OPENROUTER_API_KEY  "${OPENROUTER_API_KEY}"
[[ -n "${AGENT_LAT}" ]] && write_env AGENT_LAT "${AGENT_LAT}"
[[ -n "${AGENT_LON}" ]] && write_env AGENT_LON "${AGENT_LON}"
ok "secrets written to ${ENV_FILE} (mode 600)"

# ── 7b. Apply local patches ──────────────────────────────────────────
# Replay the workflow's hermes-agent patches on top of upstream. This
# step runs AFTER the editable install (so HERMES_AGENT_REPO is a real
# git checkout) and BEFORE the smoke test (so the gateway boots with
# the patches applied). The script is idempotent — re-running bootstrap
# won't re-apply if nothing has changed.
section "Apply hermes-agent patches"

HERMES_AGENT_PATH="${HERMES_AGENT_REPO}" \
  "${REPO}/scripts/apply-patches.sh"

# ── 7c. Install claude-remote shell function ─────────────────────────
# Drops the `claude-remote` function into the user's shell rc file so
# they can launch a tmux + Claude Code remote-control session from any
# shell on this host. Skipped (with a warning) if tmux or claude aren't
# installed yet — the user can re-run scripts/setup-remote-claude.sh
# later.
section "Remote-claude shell function"

if command -v tmux >/dev/null 2>&1 && command -v claude >/dev/null 2>&1; then
  HERMES_INSTANCE_REPO="${REPO}" \
    "${REPO}/scripts/setup-remote-claude.sh"
else
  warn "tmux or claude (Claude Code CLI) not on PATH — skipping claude-remote setup."
  warn "  Re-run scripts/setup-remote-claude.sh once both are installed."
fi

# ── 8. Smoke-test ────────────────────────────────────────────────────
# Endpoint choice: hermes-gateway exposes /health on its API server port
# (default 8642 — see hermes-agent/gateway/platforms/api_server.py
# DEFAULT_PORT). Verified live: curl http://localhost:8642/health
# returns {"status": "ok", "platform": "hermes-agent"}. The /api/rtc/health
# path mentioned in the brief is sidekick-side; we test the gateway
# instead because that's what proves the workflow stack is up.
section "Smoke test"

start_unit() {
  local unit="$1"
  if [[ ! -f "${SYSTEMD_DST}/${unit}.service" ]]; then
    warn "${unit}.service not installed — skipping start"
    return
  fi
  systemctl --user start "${unit}.service" || warn "${unit} failed to start (check: journalctl --user -u ${unit} -n 50)"
}
start_unit hermes-gateway
start_unit hermes-dashboard
start_unit hindsight-server

# Give the gateway a few seconds to bind before we probe.
HEALTH_URL="http://127.0.0.1:8642/health"
info "probing ${HEALTH_URL}"
for _ in $(seq 1 15); do
  if curl -fsS --max-time 2 "${HEALTH_URL}" >/dev/null 2>&1; then
    ok "gateway healthy at ${HEALTH_URL}"
    break
  fi
  sleep 1
done
if ! curl -fsS --max-time 2 "${HEALTH_URL}" >/dev/null 2>&1; then
  warn "gateway did not respond on ${HEALTH_URL} after 15s — check: journalctl --user -u hermes-gateway -n 100"
fi

# ── 9. Next steps ────────────────────────────────────────────────────
section "Next steps"

cat <<EOF
  ${C_BOLD}Open the sidekick PWA${C_RESET}
    cd ${SIDEKICK_PATH} && npm install && npm run dev
    (or open the deployed URL once you've configured one)

  ${C_BOLD}Update later${C_RESET}
    cd ${REPO} && git pull && ./scripts/bootstrap.sh
    (re-running is safe; existing state is preserved)

  ${C_BOLD}Inspect services${C_RESET}
    systemctl --user status hermes-gateway hermes-dashboard hindsight-server
    journalctl --user -u hermes-gateway -f

  ${C_BOLD}Edit your config${C_RESET}
    \$EDITOR ${HERMES_HOME}/config.yaml
    (it's symlinked to ${REPO}/example.config.yaml — copy first if you
    want per-instance changes that aren't tracked by the framework repo)

EOF
ok "bootstrap complete"
