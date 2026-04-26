#!/usr/bin/env bash
#
# One-shot installer for hermes-agent-workflow. Clones this repo to a
# local directory and opens Claude Code in it; AGENTS.md takes over from
# there (forking to your own private repo, prompting for keys, running
# bootstrap.sh).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/jscholz/hermes-agent-workflow/main/install.sh | bash
#
# Or, with a custom target directory:
#   curl -fsSL https://raw.githubusercontent.com/jscholz/hermes-agent-workflow/main/install.sh | bash -s -- ~/path/of/your/choice

set -euo pipefail

readonly REPO_URL="https://github.com/jscholz/hermes-agent-workflow.git"
readonly DEFAULT_TARGET="${HOME}/code/hermes-agent-workflow"
TARGET="${1:-${DEFAULT_TARGET}}"

# Color helpers (no external deps).
if [[ -t 1 ]]; then
  c_g=$'\033[32m'; c_r=$'\033[31m'; c_y=$'\033[33m'; c_0=$'\033[0m'
else
  c_g=''; c_r=''; c_y=''; c_0=''
fi
ok()   { printf '%s✓%s %s\n'  "$c_g" "$c_0" "$*"; }
warn() { printf '%s!%s %s\n'  "$c_y" "$c_0" "$*"; }
die()  { printf '%s✗%s %s\n' "$c_r" "$c_0" "$*" >&2; exit 1; }

# Prereqs. Each missing tool prints a platform-aware install hint and
# tells the user how to resume after they fix it (the rest of install.sh
# is idempotent — re-running picks up where it left off).
miss_prereq() {
  local name="$1" install_hint="$2"
  printf '%s✗%s %s not found on PATH.\n\n' "$c_r" "$c_0" "$name" >&2
  printf 'Install it, then resume by re-running:\n\n' >&2
  printf '    curl -fsSL https://raw.githubusercontent.com/jscholz/hermes-agent-workflow/main/install.sh | bash\n\n' >&2
  printf 'Install hint:\n  %s\n\n' "$install_hint" >&2
  exit 1
}

command -v git >/dev/null \
  || miss_prereq "git" "Linux: 'sudo apt install git'  ·  macOS: 'xcode-select --install' or 'brew install git'"
command -v claude >/dev/null \
  || miss_prereq "claude (Claude Code)" "https://claude.com/claude-code — install + run 'claude' once to log in before re-running this script"
command -v tmux >/dev/null \
  || miss_prereq "tmux" "Linux: 'sudo apt install tmux' (Debian/Ubuntu) / 'sudo dnf install tmux' (Fedora)  ·  macOS: 'brew install tmux'"

# Clone (or reuse existing checkout if it points at the right remote).
if [[ -d "${TARGET}" ]]; then
  if [[ -d "${TARGET}/.git" ]] && \
     git -C "${TARGET}" remote get-url origin 2>/dev/null | grep -q "hermes-agent-workflow"; then
    ok "found existing clone at ${TARGET}, skipping clone"
  else
    die "${TARGET} exists and isn't a hermes-agent-workflow checkout. Move it aside or pass a different path: bash install.sh /your/path"
  fi
else
  ok "cloning ${REPO_URL} → ${TARGET}"
  mkdir -p "$(dirname "${TARGET}")"
  git clone "${REPO_URL}" "${TARGET}"
fi

cd "${TARGET}"

# Spawn a tmux + claude remote-control session — same shape the
# `claude-remote` bash function will use after bootstrap installs it,
# so this initial setup session is reachable from the same terminal
# AND from claude.ai/code AND from the iOS Claude app from the start.
# Using a canonical session name (claude-<hostname>) means the
# bash function (when it lands later) detects the session as already
# running and no-ops on first invocation.
readonly HOST_NAME_DERIVED="${HOST_NAME:-$(hostname -s)}"
readonly SESS="claude-${HOST_NAME_DERIVED}"

readonly KICKOFF='Read claude-session-history.md and AGENTS.md end-to-end, then walk me through the first-run setup. Specifically: check whether I am on my own private fork (Step 1a), help me create one if not, and then run scripts/bootstrap.sh. Be proactive — do the work, do not ask me to confirm each individual step unless something is genuinely ambiguous.'

if tmux has-session -t "$SESS" 2>/dev/null; then
  warn "tmux session '${SESS}' already exists — attaching to it (kickoff prompt skipped)"
  exec tmux attach -t "$SESS"
fi

ok "spawning Claude remote-control session: ${SESS}"
tmux new-session -d -s "$SESS" -x 200 -y 50 \
  "cd ${TARGET} && claude remote-control --name ${SESS}"

# Wait for Claude to initialize before sending the kickoff. Mirrors
# the 5s delay in the claude-remote bash function — empirically
# enough for the REPL to be ready to accept input on a fresh nook.
( sleep 5 && tmux send-keys -t "$SESS" "$KICKOFF" Enter ) &

echo
echo "──────────────────────────────────────────────────────────────────────"
echo "  Your Claude session is live. Three ways to interact:"
echo
echo "  1. This terminal — you'll be attached in a moment."
echo "  2. https://claude.ai/code  →  pick session '${SESS}'"
echo "  3. iOS Claude app: Code tab  →  pick '${SESS}'"
echo
echo "  Detach the terminal with Ctrl-b then d (session keeps running)."
echo "  After bootstrap finishes, the same session is reachable as"
echo "  'claude-remote' from any new shell on this machine."
echo "──────────────────────────────────────────────────────────────────────"
echo
sleep 1
exec tmux attach -t "$SESS"
