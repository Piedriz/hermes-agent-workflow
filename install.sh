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

# Spawn a tmux session running plain `claude` (NOT remote-control) for
# the install. Reasoning:
#
#   - The user is at this machine's terminal during install — they
#     don't need browser/iOS access for the 5-10 min bootstrap. They
#     get that AFTER bootstrap, via the `claude-remote` bash function
#     setup-remote-claude.sh installs.
#
#   - `claude remote-control` is a session SPAWNER, not a REPL. Its
#     pane shows a "Choose spawn mode [1/2]" picker on first run and
#     a key-binding listener after — neither accepts our kickoff
#     prompt via tmux send-keys, so the auto-kickoff UX falls apart.
#
#   - Plain `claude "$KICKOFF"` is a real REPL with the kickoff
#     baked in as the first turn. send-keys also works as a fallback
#     if we want to send follow-ups.
#
# Session name is install-specific (`hermes-install`) rather than the
# canonical `claude-<hostname>` that claude-remote uses, so when the
# user runs claude-remote post-bootstrap it spawns fresh with full
# remote-control — no confusion between "the install session" and
# "my ongoing remote session".
readonly SESS="hermes-install"

readonly KICKOFF='Read claude-session-history.md and AGENTS.md end-to-end, then walk me through the first-run setup. Specifically: check whether I am on my own private fork (Step 1a), help me create one if not, and then run scripts/bootstrap.sh. Be proactive — do the work, do not ask me to confirm each individual step unless something is genuinely ambiguous.'

if tmux has-session -t "$SESS" 2>/dev/null; then
  warn "tmux session '${SESS}' already exists — attaching to it (kickoff prompt skipped)"
  if [[ -t 0 ]]; then exec tmux attach -t "$SESS"; fi
  echo "  Attach with: tmux attach -t ${SESS}"
  exit 0
fi

ok "spawning install Claude session in tmux: ${SESS}"
# Plain `claude "$KICKOFF"` — Claude takes a positional [prompt] arg
# that fires as the first turn while keeping the session interactive.
# printf %q shell-escapes the kickoff string for the child-shell
# command line so embedded quotes / backticks survive.
KICKOFF_Q="$(printf %q "$KICKOFF")"
tmux new-session -d -s "$SESS" -x 200 -y 50 \
  "cd ${TARGET} && claude ${KICKOFF_Q}"

echo
echo "──────────────────────────────────────────────────────────────────────"
echo "  Your install Claude session is live in tmux session '${SESS}'."
echo "  The kickoff prompt has been queued; Claude will start working as"
echo "  soon as you attach."
echo
if [[ -t 0 ]]; then
  echo "  Attaching now. Detach with Ctrl-b then d (session keeps running)."
  echo "──────────────────────────────────────────────────────────────────────"
  echo
  sleep 1
  exec tmux attach -t "$SESS"
else
  # curl | bash has no TTY — tmux attach would fail. Session is alive;
  # user attaches manually from their shell.
  echo "  This shell has no TTY (curl-pipe mode). Attach manually:"
  echo
  echo "      tmux attach -t ${SESS}"
  echo
  echo "  Detach with Ctrl-b then d. After bootstrap finishes, the more"
  echo "  full-featured 'claude-remote' command (browser/iOS access too)"
  echo "  will be available from any new shell."
  echo "──────────────────────────────────────────────────────────────────────"
  echo
fi
