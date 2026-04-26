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

# Prereqs.
command -v git    >/dev/null || die "git not found on PATH. Install git, then retry."
command -v claude >/dev/null || die "claude not found on PATH. Install Claude Code first: https://claude.com/claude-code"

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
ok "opening Claude Code in ${TARGET}"
warn "AGENTS.md will walk you through forking this to your own private repo and running bootstrap.sh."
echo
exec claude
