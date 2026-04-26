#!/usr/bin/env bash
# hermes-agent-workflow / scripts / update-workflow.sh
#
# Pull the latest workflow framework + patch set, then re-apply patches
# to the live hermes-agent checkout. This is the "stay current" command
# for contributors who aren't actively developing patches themselves.
#
# WHY --ff-only:
#   Divergent history between your fork and upstream means you've edited
#   framework files (the very thing the framework/instance split tells
#   you not to do). That's a contributor problem to handle manually —
#   we don't paper over it with a merge commit.
#
# Usage:
#   scripts/update-workflow.sh
set -euo pipefail

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

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "${REPO}"

section "Pull workflow updates"
info "pulling --ff-only in ${REPO}"
if ! git pull --ff-only; then
  fail "git pull --ff-only refused. Your fork has diverged from upstream;
       resolve manually (rebase or reset) before re-running. The framework /
       instance split (see AGENTS.md) is what keeps this rare — diverging
       usually means you edited a framework file. Move that change into
       scripts/extensions/ or send it upstream."
fi
ok "workflow up to date"

section "Apply patches"
"${REPO}/scripts/apply-patches.sh"

section "Next steps"
cat <<EOF
  ${C_BOLD}Verify services${C_RESET}
    systemctl --user status hermes-gateway hermes-dashboard hindsight-server
    journalctl --user -u hermes-gateway -n 50

  ${C_BOLD}Smoke-test the gateway${C_RESET}
    curl -fsS http://127.0.0.1:8642/health

  If a service failed to come back up, check its journal first.
  If a patch failed to apply, see scripts/apply-patches.sh output above
  and PATCHES.md for what each patch does.
EOF
ok "update complete"
