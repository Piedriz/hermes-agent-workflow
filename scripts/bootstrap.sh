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
#   The user will run this multiple times: once to bootstrap, once after
#   they learn about a new env var, once when they debug a failing
#   service. Every step must check state first.
set -euo pipefail

# ── 0. Argument parsing + repo location + UI helpers ─────────────────
# Two run modes:
#   * Interactive (default): prompts you for each value not already set
#     in the environment. This is what you get from a normal shell run.
#   * Unattended (--unattended or --env-file <path>): all values must
#     come from the environment; missing required values cause a
#     fail-fast abort. Designed so an agent (Claude Code, a CI runner,
#     etc.) can drive the install without a TTY.
#
# Env-file mode reads KEY=VALUE pairs from the file (one per line, '#'
# comments OK) and exports them, then runs unattended. The file is NOT
# deleted by the script — caller is responsible for cleanup, since
# they wrote it.
UNATTENDED=0
ENV_FILE_ARG=""
while (( $# > 0 )); do
  case "$1" in
    --unattended) UNATTENDED=1; shift ;;
    --env-file)
      shift
      [[ -n "${1:-}" ]] || { echo "--env-file requires a path" >&2; exit 2; }
      ENV_FILE_ARG="$1"; UNATTENDED=1; shift ;;
    --env-file=*) ENV_FILE_ARG="${1#--env-file=}"; UNATTENDED=1; shift ;;
    -h|--help)
      cat <<EOF
Usage: bootstrap.sh [--unattended] [--env-file <path>]

  Interactive (default): prompts for each value not pre-set in env.

  --unattended            Fail if any required value is missing from
                          the environment. No prompts.
  --env-file <path>       Read KEY=VALUE pairs from <path> (sourced),
                          implies --unattended.

Recognized variables (set via env or env-file):
  HOST_NAME              host name; default: hostname -s
  SIDEKICK_PATH          sidekick clone path; default: ~/code/sidekick
  SIDEKICK_TLS_DIR       HTTPS cert/key dir; default: ~/.local/share/sidekick/tls
  HERMES_HOME            hermes home; default: ~/.hermes
  AGENT_LAT, AGENT_LON   ambient weather coords; optional
  DEEPGRAM_API_KEY       required (unless ~/.hermes/.env already has it)
  OPENROUTER_API_KEY     required (unless ~/.hermes/.env already has it)
  TAVILY_API_KEY         optional (enables web_search tool); skip with empty value
EOF
      exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -n "${ENV_FILE_ARG}" ]]; then
  [[ -r "${ENV_FILE_ARG}" ]] || { echo "env-file not readable: ${ENV_FILE_ARG}" >&2; exit 2; }
  # shellcheck disable=SC1090
  set -a; source "${ENV_FILE_ARG}"; set +a
fi

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
need openssl "apt install openssl  |  brew install openssl"

# python3.11+ check — uv would catch this later but a clear message now
# saves the user 10 minutes of confusing tracebacks.
if ! command -v python3 >/dev/null 2>&1; then
  fail "python3 not on PATH. Install Python 3.11+ first."
fi
PY_VER="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
PY_MAJ="${PY_VER%.*}"; PY_MIN="${PY_VER#*.}"
if (( PY_MAJ < 3 || (PY_MAJ == 3 && PY_MIN < 11) )); then
  fail "python3 is ${PY_VER}, need >=3.11. Install Python 3.11+ (uv can manage one: uv python install 3.11)."
fi
ok "python3 ${PY_VER}"

# Node 20+ check. Sidekick proxy uses experimental TypeScript stripping
# (--experimental-strip-types) which lands stably in Node 22, but is
# usable from 20+. We do not pin a specific minor — whatever the user
# has on PATH that is >=20 works. If you need a managed Node, install
# nvm or fnm yourself; we deliberately don't manage Node for you.
if ! command -v node >/dev/null 2>&1; then
  fail "node not on PATH. Install Node 20+ (recommend nvm: https://github.com/nvm-sh/nvm)."
fi
NODE_VER="$(node -v 2>/dev/null | sed 's/^v//')"
NODE_MAJ="${NODE_VER%%.*}"
if (( NODE_MAJ < 20 )); then
  fail "node is v${NODE_VER}, need >=20 for the sidekick proxy. Upgrade (e.g. via nvm: 'nvm install 22 && nvm use 22')."
fi
ok "node v${NODE_VER}"

# ── 2. Prompt for config ─────────────────────────────────────────────
# We persist answers as a side-effect of writing them into ~/.hermes/.env
# (secrets) and downstream files (host name → systemd unit names). On
# re-runs we detect those and skip the prompt — never re-ask for keys.
section "Configuration"

ENV_FILE_DEFAULT="${HOME}/.hermes/.env"
HERMES_HOME_DEFAULT="${HOME}/.hermes"
SIDEKICK_PATH_DEFAULT="${HOME}/code/sidekick"
SIDEKICK_TLS_DIR_DEFAULT="${HOME}/.local/share/sidekick/tls"

prompt_default() {
  # prompt_default <var-name> <prompt-text> <default> [--required]
  # Interactive: prompts the user, falling back to <default> on Enter.
  # Unattended: uses the env-set value, falling back to <default>;
  # fails if --required and neither env nor default is non-empty.
  local var="$1" text="$2" default="$3" required="${4:-}"
  local current="${!var:-}"
  if [[ -n "${current}" ]]; then
    ok "${var}=${current} (from environment)"
    return
  fi
  if (( UNATTENDED )); then
    if [[ -n "${default}" ]]; then
      printf -v "${var}" '%s' "${default}"
      export "${var}"
      ok "${var}=${default} (unattended default)"
      return
    fi
    if [[ "${required}" == "--required" ]]; then
      fail "${var} is required (set it in the environment or env-file before re-running)."
    fi
    printf -v "${var}" '%s' ""
    export "${var}"
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
  # Reads silently in interactive mode. Skipped if .env already has the
  # key. Unattended: uses env-set value; fails if --required and unset.
  local var="$1" text="$2" required="${3:-}"
  local env_file="${HERMES_HOME}/.env"
  if [[ -f "${env_file}" ]] && grep -qE "^${var}=" "${env_file}"; then
    ok "${var} found in ${env_file}, leaving as-is"
    printf -v "${var}" '%s' "__KEEP__"
    export "${var}"
    return
  fi
  local current="${!var:-}"
  if [[ -n "${current}" ]]; then
    ok "${var} set from environment (will be written to .env)"
    return
  fi
  if (( UNATTENDED )); then
    if [[ "${required}" == "--required" ]]; then
      fail "${var} is required (set it in the environment or env-file before re-running)."
    fi
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
prompt_default SIDEKICK_TLS_DIR "Sidekick HTTPS cert/key directory" "${SIDEKICK_TLS_DIR_DEFAULT}"
prompt_default HERMES_HOME    "hermes home directory" "${HERMES_HOME_DEFAULT}"
prompt_default AGENT_LAT      "agent latitude (for ambient weather widget, optional)" ""
prompt_default AGENT_LON      "agent longitude (for ambient weather widget, optional)" ""

# Make sure HERMES_HOME exists before we look in it for an existing .env.
mkdir -p "${HERMES_HOME}"

# Secret prompts — only ask if .env doesn't already have them
prompt_secret  DEEPGRAM_API_KEY    "Deepgram API key (for STT)"                    --required
prompt_secret  OPENROUTER_API_KEY  "OpenRouter API key (for LLM access)"           --required
# Optional: empty value skips. The web_search tool auto-detects this in
# hermes via TAVILY_API_KEY; absent → tool not registered.
prompt_secret  TAVILY_API_KEY      "Tavily API key (for web_search, optional)"

# ── 3. Sidekick clone ────────────────────────────────────────────────
# The PWA + audio bridge live in a separate public repo. We clone as a
# sibling directory rather than as a submodule so the user can pull
# updates independently of the workflow framework version.
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

# Sidekick voice capture, push, PWA install behavior, and WebRTC require
# a browser secure context when the UI is opened from another device.
# Localhost is exempt, but a home-server install almost always gets used
# from a laptop/phone, so generate a host-local self-signed certificate
# and configure Sidekick to serve HTTPS by default. Users who want a
# trusted certificate with no browser warning can later replace this with
# Tailscale Serve, Caddy, nginx, etc.
section "Sidekick HTTPS"

mkdir -p "${SIDEKICK_TLS_DIR}"
chmod 700 "${SIDEKICK_TLS_DIR}"
SIDEKICK_CERT_FILE="${SIDEKICK_TLS_DIR}/sidekick.crt"
SIDEKICK_KEY_FILE="${SIDEKICK_TLS_DIR}/sidekick.key"

if [[ -f "${SIDEKICK_CERT_FILE}" && -f "${SIDEKICK_KEY_FILE}" ]]; then
  ok "Sidekick TLS cert/key already exist in ${SIDEKICK_TLS_DIR}"
else
  SAN="DNS:${HOST_NAME},DNS:${HOST_NAME}.local,IP:127.0.0.1"
  if command -v tailscale >/dev/null 2>&1; then
    ts_ip="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
    ts_dns="$(tailscale status --json 2>/dev/null | python3 -c 'import sys,json; data=json.load(sys.stdin); print(data.get("Self",{}).get("DNSName","").rstrip("."))' 2>/dev/null || true)"
    [[ -n "${ts_ip}" ]] && SAN="${SAN},IP:${ts_ip}"
    [[ -n "${ts_dns}" ]] && SAN="${SAN},DNS:${ts_dns}"
  fi
  info "generating Sidekick self-signed HTTPS certificate"
  openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
    -keyout "${SIDEKICK_KEY_FILE}" \
    -out "${SIDEKICK_CERT_FILE}" \
    -subj "/CN=${HOST_NAME}" \
    -addext "subjectAltName=${SAN}" >/dev/null 2>&1
  chmod 600 "${SIDEKICK_CERT_FILE}" "${SIDEKICK_KEY_FILE}"
  ok "generated ${SIDEKICK_CERT_FILE}"
fi

SIDEKICK_ENV_FILE="${SIDEKICK_PATH}/.env"
touch "${SIDEKICK_ENV_FILE}"
chmod 600 "${SIDEKICK_ENV_FILE}"
write_sidekick_env() {
  local key="$1" val="$2" tmp
  if grep -qE "^${key}=" "${SIDEKICK_ENV_FILE}"; then
    tmp="${SIDEKICK_ENV_FILE}.tmp"
    sed "s|^${key}=.*|${key}=${val}|" "${SIDEKICK_ENV_FILE}" > "${tmp}"
    mv "${tmp}" "${SIDEKICK_ENV_FILE}"
  else
    printf '%s=%s\n' "${key}" "${val}" >> "${SIDEKICK_ENV_FILE}"
  fi
  chmod 600 "${SIDEKICK_ENV_FILE}"
}
write_sidekick_env SIDEKICK_HTTPS_CERT_FILE "${SIDEKICK_CERT_FILE}"
write_sidekick_env SIDEKICK_HTTPS_KEY_FILE "${SIDEKICK_KEY_FILE}"
ok "configured Sidekick HTTPS in ${SIDEKICK_ENV_FILE}"

# ── 4. Symlink layout ────────────────────────────────────────────────
# The workflow repo IS the source of truth for config + state — ~/.hermes/
# is a façade pointing back at versioned files in this repo. See
# README.md "What gets versioned in your fork" for the full state map.
#
# Two link shapes:
#   - link_template: repo path is a "*.example" template that becomes
#     the live file (e.g., example.config.yaml → ~/.hermes/config.yaml).
#     Skipped silently if user already has a non-symlink at the live
#     path (assume they know what they're doing).
#   - link_dir: repo path is the directory itself, becomes the live
#     directory (e.g., skills/ → ~/.hermes/skills/).
#
# Encrypted-at-rest entries (.env, auth.json, OAuth tokens, whatsapp
# session, hindsight + state.db dumps) are also wired here. They're
# git-crypt'd via .gitattributes patterns; the symlink works the same
# way regardless of plaintext-vs-encrypted-in-history.
section "Symlink layout"

link_template() {
  # link_template <repo-relative-template> <hermes-relative-target>
  local tmpl="${REPO}/$1" live="${HERMES_HOME}/$2"
  if [[ ! -e "${tmpl}" ]]; then
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

link_dir() {
  # link_dir <repo-relative-dir> <hermes-relative-dir>
  # Symlinks an entire directory from the repo into ~/.hermes/. The repo
  # dir must exist (use a .gitkeep marker if seeded empty).
  local src="${REPO}/$1" live="${HERMES_HOME}/$2"
  if [[ ! -d "${src}" ]]; then
    warn "directory missing in repo: $1 (skipping)"
    return
  fi
  if [[ -L "${live}" ]]; then
    local current; current="$(readlink "${live}")"
    if [[ "${current}" == "${src}" ]]; then
      ok "${live} already linked"
      return
    fi
    warn "relinking ${live} (was → ${current})"
    rm "${live}"
  elif [[ -d "${live}" ]] && [[ -n "$(ls -A "${live}" 2>/dev/null)" ]]; then
    warn "${live} exists with content — leaving as-is (manual migration if you want it versioned)"
    return
  elif [[ -e "${live}" ]]; then
    warn "${live} is a regular file — leaving as-is"
    return
  elif [[ -d "${live}" ]]; then
    rmdir "${live}" 2>/dev/null || true
  fi
  mkdir -p "$(dirname "${live}")"
  ln -s "${src}" "${live}"
  ok "linked ${live}/ → ${src}/"
}

link_secret() {
  # link_secret <repo-relative-target> <hermes-relative-target>
  # Symlinks an encrypted-at-rest file (or one prompted-into during
  # bootstrap, e.g. .env). Skips if repo target doesn't exist yet —
  # bootstrap §7 (Secrets → .env) creates it; subsequent runs link it.
  local src="${REPO}/$1" live="${HERMES_HOME}/$2"
  if [[ ! -e "${src}" ]]; then
    return  # silently — these get created later
  fi
  if [[ -L "${live}" ]]; then
    ok "${live} already linked"
    return
  fi
  if [[ -e "${live}" ]]; then
    warn "${live} exists (regular file) — leaving as-is"
    return
  fi
  mkdir -p "$(dirname "${live}")"
  ln -s "${src}" "${live}"
  ok "linked ${live} → ${src}"
}

# Templates → live config files (plaintext, never encrypted)
link_template "example.config.yaml"            "config.yaml"
link_template "example.AGENTS.md"              "AGENTS.md"
link_template "SOUL.md.template"               "SOUL.md"
link_template "example.hindsight.config.json"  "hindsight/config.json"

# Versioned state directories (plaintext)
link_dir "memories"           "memories"
link_dir "skills"             "skills"
link_dir "cron"               "cron"
link_dir "hooks"              "hooks"
link_dir "plugins"            "plugins"
# ~/.hermes/scripts hosts agent-runtime callables — cron-driven Python
# scripts and skill helpers. Symlinking means any script the agent
# (or you) drops there lands in your fork automatically and survives
# host migrations. The repo ships an empty hermes-runtime-scripts/ dir
# (with .gitkeep); user-specific scripts (e.g. notion daily-planner
# rollover) accumulate over time and ride along with your fork.
# Field bug 2026-05-11 (the original install pattern omitted this):
# a host migration silently lost the user's notion cron script because
# it had no canonical location in any tracked repo — added here so
# subsequent installs don't repeat the mistake.
link_dir "hermes-runtime-scripts"  "scripts"

# Versioned state directories (git-crypt encrypted via .gitattributes —
# the symlink works the same; encryption applies in git history).
link_dir "whatsapp"           "whatsapp"
link_dir "pairing"            "pairing"

# Encrypted secrets — created later by bootstrap §7 (.env) or by user
# action (auth.json from `hermes auth`, OAuth tokens via gog/google-workspace).
# link_secret is a no-op until the file exists; subsequent bootstrap
# runs pick them up.
link_secret ".env"                       ".env"
link_secret "auth.json"                  "auth.json"
link_secret "google_client_secret.json"  "google_client_secret.json"
link_secret "google_token.json"          "google_token.json"

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

# ── 5b. Hindsight client (in the hermes-agent venv) ──────────────────
# The hindsight memory plugin (plugins/memory/hindsight in upstream
# hermes-agent) imports `hindsight_client`. That dep is on PyPI as
# `hindsight-client`, distinct from the server's `hindsight-api-slim`
# we install above. The plugin has a runtime auto-upgrade path, but it
# can only fire AFTER the package is importable — first install has to
# happen out-of-band. Without this step, hindsight memory writes
# silently fall back to "broken locally" with
# `ModuleNotFoundError: No module named 'hindsight_client'`.
section "Hindsight client"

if [[ -x "${HERMES_VENV}/bin/python" ]]; then
  if "${HERMES_VENV}/bin/python" -c 'import hindsight_client' 2>/dev/null; then
    ok "hindsight-client already importable in ${HERMES_VENV}"
  else
    info "installing hindsight-client into ${HERMES_VENV}"
    uv pip install --python "${HERMES_VENV}/bin/python" 'hindsight-client>=0.4.22'
    ok "hindsight-client installed"
  fi
else
  warn "${HERMES_VENV} not present — skip hindsight-client install"
fi

# ── 5c. Claude-Code memory dir (with resume protocol) ────────────────
# Each host's claude-code memory dir lives under hosts/<host>/claude-code-memory/
# in the workflow repo. We seed it from templates/claude-code-memory/
# (RESUME.md stub + feedback_resume_protocol.md) so a fresh-host claude
# session resume reads the protocol on day one. Then we symlink the
# live ~/.claude/projects/<encoded-cwd>/memory dir at it so memory
# writes from the running session land back in the repo.
section "Claude Code memory + resume protocol"

HOST_MEMORY_DIR="${REPO}/hosts/${HOST_NAME}/claude-code-memory"
TEMPLATE_MEMORY_DIR="${REPO}/templates/claude-code-memory"
mkdir -p "${HOST_MEMORY_DIR}"

# Seed RESUME.md stub if missing. The protocol expects this file to
# exist on session resume; without it the discipline can't bootstrap.
if [[ ! -f "${HOST_MEMORY_DIR}/RESUME.md" && -f "${TEMPLATE_MEMORY_DIR}/RESUME.md" ]]; then
  cp "${TEMPLATE_MEMORY_DIR}/RESUME.md" "${HOST_MEMORY_DIR}/RESUME.md"
  ok "seeded ${HOST_MEMORY_DIR}/RESUME.md"
fi

# Seed the resume-protocol feedback file if missing.
if [[ ! -f "${HOST_MEMORY_DIR}/feedback_resume_protocol.md" \
      && -f "${TEMPLATE_MEMORY_DIR}/feedback_resume_protocol.md" ]]; then
  cp "${TEMPLATE_MEMORY_DIR}/feedback_resume_protocol.md" \
     "${HOST_MEMORY_DIR}/feedback_resume_protocol.md"
  ok "seeded ${HOST_MEMORY_DIR}/feedback_resume_protocol.md"
fi

# Ensure MEMORY.md indexes the protocol entries. If MEMORY.md doesn't
# exist, create it with just those entries; otherwise prepend.
MEMORY_INDEX="${HOST_MEMORY_DIR}/MEMORY.md"
PROTOCOL_LINES=$'- [RESUME — read FIRST on any resume](RESUME.md) — Live state of the in-flight conversation, refreshed each meaningful turn. May be missing on a brand-new session — if so, create one. If its timestamp is stale, also tail the `.jsonl` it points at for verbatim context.\n- [Resume protocol — keep RESUME.md current](feedback_resume_protocol.md) — After each meaningful exchange, refresh `RESUME.md` before responding. That\'s the discipline that makes mid-session crash recovery work.\n'
if [[ ! -f "${MEMORY_INDEX}" ]]; then
  printf '%s' "${PROTOCOL_LINES}" > "${MEMORY_INDEX}"
  ok "seeded MEMORY.md with resume protocol entries"
elif ! grep -q '\[RESUME ' "${MEMORY_INDEX}" 2>/dev/null; then
  TMP_MEM="$(mktemp)"
  printf '%s' "${PROTOCOL_LINES}" > "${TMP_MEM}"
  cat "${MEMORY_INDEX}" >> "${TMP_MEM}"
  mv "${TMP_MEM}" "${MEMORY_INDEX}"
  ok "prepended resume protocol pointers to MEMORY.md"
fi

# Symlink ~/.claude/projects/<encoded-cwd>/memory at the host memory
# dir. Claude Code encodes the project cwd by replacing '/' with '-',
# so a checkout at ${REPO} becomes "$(echo "${REPO}" | tr '/' '-')".
# We also cover the $HOME-launched encoding (for users who run
# claude-remote from $HOME — see scripts/setup-remote-claude.sh).
encoded_repo="$(echo "${REPO}" | tr '/' '-')"
encoded_home="$(echo "${HOME}" | tr '/' '-')"
CLAUDE_PROJECT_PARENTS=(
  "${HOME}/.claude/projects/${encoded_repo}"
  "${HOME}/.claude/projects/${encoded_home}"
)
for parent in "${CLAUDE_PROJECT_PARENTS[@]}"; do
  [[ -d "${parent}" || -L "${parent}" ]] || continue
  live_memory="${parent}/memory"
  if [[ -L "${live_memory}" ]]; then
    continue
  fi
  if [[ -d "${live_memory}" && ! -L "${live_memory}" ]]; then
    warn "${live_memory} is a regular dir, not a symlink — leaving alone (manual migration needed)"
    continue
  fi
  ln -s "${HOST_MEMORY_DIR}" "${live_memory}"
  ok "symlinked ${live_memory} → ${HOST_MEMORY_DIR}"
done

# ── 6. systemd user units ────────────────────────────────────────────
# Generate per-user units from templates by substituting placeholders.
# We deliberately don't enable --now here; smoke-test step starts them
# explicitly so failures surface immediately instead of getting buried
# in journalctl.
section "systemd user units"

SYSTEMD_DST="${HOME}/.config/systemd/user"
mkdir -p "${SYSTEMD_DST}"
NODE_BIN_DIR="$(dirname "$(command -v node)")"

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
    -e "s|{{NODE_BIN_DIR}}|${NODE_BIN_DIR}|g" \
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
render_unit "systemd/sidekick.service"         "sidekick.service"

# Sidekick audio bridge unit lives in the sidekick checkout, not in
# this workflow repo (so sidekick can ship breaking changes to the unit
# without requiring a workflow-repo bump). Symlink the file from the
# sidekick clone into ~/.config/systemd/user/ so systemctl picks it up
# alongside the workflow units. We do NOT render placeholders into it —
# the upstream unit uses systemd's %h specifier which already expands to
# $HOME at unit-load time, so it works as-is across hosts.
SIDEKICK_AUDIO_SRC="${SIDEKICK_PATH}/audio-bridge/sidekick-audio.service"
SIDEKICK_AUDIO_DST="${SYSTEMD_DST}/sidekick-audio.service"
if [[ -f "${SIDEKICK_AUDIO_SRC}" ]]; then
  if [[ -L "${SIDEKICK_AUDIO_DST}" ]]; then
    current="$(readlink "${SIDEKICK_AUDIO_DST}")"
    if [[ "${current}" != "${SIDEKICK_AUDIO_SRC}" ]]; then
      rm "${SIDEKICK_AUDIO_DST}"
      ln -s "${SIDEKICK_AUDIO_SRC}" "${SIDEKICK_AUDIO_DST}"
      ok "relinked ${SIDEKICK_AUDIO_DST} → ${SIDEKICK_AUDIO_SRC}"
    else
      ok "${SIDEKICK_AUDIO_DST} already linked"
    fi
  elif [[ -e "${SIDEKICK_AUDIO_DST}" ]]; then
    warn "${SIDEKICK_AUDIO_DST} is a regular file (not a symlink) — leaving as-is"
  else
    ln -s "${SIDEKICK_AUDIO_SRC}" "${SIDEKICK_AUDIO_DST}"
    ok "linked ${SIDEKICK_AUDIO_DST} → ${SIDEKICK_AUDIO_SRC}"
  fi
else
  warn "sidekick audio-bridge unit not found at ${SIDEKICK_AUDIO_SRC} — skipping"
fi

systemctl --user daemon-reload
ok "systemctl --user daemon-reload"

# ── 7. Secrets → .env ────────────────────────────────────────────────
# We append rather than overwrite — the user may have other env vars
# in there from a prior run or manual edit. chmod 600 every time
# defensively.
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
write_env TAVILY_API_KEY      "${TAVILY_API_KEY:-}"
[[ -n "${AGENT_LAT}" ]] && write_env AGENT_LAT "${AGENT_LAT}"
[[ -n "${AGENT_LON}" ]] && write_env AGENT_LON "${AGENT_LON}"
ok "secrets written to ${ENV_FILE} (mode 600)"

# ── 7b. Apply local patches ──────────────────────────────────────────
# This template ships virgin hermes-agent — `patches/hermes-agent/` is
# empty by default, and this section is a no-op. If you've added your
# own patches (see PATCHES.md), apply-patches.sh replays them onto
# upstream here. The script is idempotent — re-running bootstrap
# won't re-apply if nothing has changed.
shopt -s nullglob
PATCHES=( "${REPO}/patches/hermes-agent"/*.patch )
shopt -u nullglob
if (( ${#PATCHES[@]} > 0 )); then
  section "Apply hermes-agent patches"
  HERMES_AGENT_PATH="${HERMES_AGENT_REPO}" \
    "${REPO}/scripts/apply-patches.sh"
else
  info "Skipping hermes-agent patch step — patches/hermes-agent/ is empty (this template ships virgin hermes-agent)."
fi

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

# ── 7d. Cron entries (idempotent) ────────────────────────────────────
# Install a small set of cron jobs that keep the on-disk runtime tidy:
#   - prune-claude-cc-history.sh: nightly trim of Claude Code .jsonl
#     transcripts older than 30d (they accumulate unbounded otherwise;
#     a single active session is multiple MB).
# More crons (e.g. periodic doctor.sh, sync jobs) can be added by the
# user as needed — this is the conservative starter set.
section "Cron"

add_cron() {
  local pattern="$1" line="$2"
  if crontab -l 2>/dev/null | grep -qF "${pattern}"; then
    ok "cron already has: ${pattern}"
    return
  fi
  (crontab -l 2>/dev/null; echo "${line}") | crontab -
  ok "added cron: ${pattern}"
}

mkdir -p "${HERMES_HOME}/logs"
if command -v crontab >/dev/null 2>&1; then
  add_cron "prune-claude-cc-history.sh" \
    "44 4 * * * ${REPO}/scripts/prune-claude-cc-history.sh >> ${HERMES_HOME}/logs/prune-claude-cc-history.log 2>&1"
else
  warn "crontab not on PATH — skipping cron install (run scripts/prune-claude-cc-history.sh manually as needed)"
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
start_unit sidekick
start_unit sidekick-audio

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
SIDEKICK_URL="https://127.0.0.1:3001/"
info "probing ${SIDEKICK_URL}"
for _ in $(seq 1 15); do
  if curl -kfsS --max-time 2 "${SIDEKICK_URL}" >/dev/null 2>&1; then
    ok "sidekick healthy at ${SIDEKICK_URL}"
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

# Sentinel — CLAUDE.md (and any future tooling) reads this to detect
# "bootstrap finished" without having to verify every individual step.
# Updated on every successful run; the mtime is the latest-bootstrap
# timestamp.
mkdir -p "${HERMES_HOME}"
date -u +%Y-%m-%dT%H:%M:%SZ > "${HERMES_HOME}/.bootstrap.complete"

ok "bootstrap complete"
