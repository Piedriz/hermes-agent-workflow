#!/usr/bin/env bash
# Prune historical hermes-data/state.sql snapshots from git history.
#
# WHY: scripts/sync-hermes-state.sh writes a fresh plaintext SQL dump
# of state.db every day. With pack-delta + zlib + git-crypt's
# deterministic per-path encryption, day-over-day deltas compress to
# ~the new content (typically <100KB on a steady chat day). But over
# months a tail of old snapshots still accumulates; this prunes that tail.
#
# This script keeps a dilated-strided sample (smaller storage, full
# recovery for recent days, coarser recovery for older periods):
#
#   - last 7 days:   keep daily       (7 snapshots)
#   - 8..30 days:    keep weekly      (~3 snapshots)
#   - 31..365 days:  keep monthly     (~11 snapshots)
#   - >365 days:     keep yearly      (~N snapshots)
#
#   Total at steady state: ~21 snapshots forever (regardless of repo age).
#
# Mechanism: git filter-repo with a commit callback that removes
# hermes-data/state.sql from non-kept commits (keeps commit metadata
# so log + history continuity stays intact; just drops the blob).
#
# AFTER RUNNING: every commit hash changes. ALL clones must re-clone
# (or do a hard reset). Force-push to origin. Run this from a repo
# you're OK rewriting — i.e., one that nobody else has open work on.
#
# Usage:
#   scripts/prune-hermes-state-history.sh                # dry-run (default)
#   scripts/prune-hermes-state-history.sh --apply        # actually rewrite
#   scripts/prune-hermes-state-history.sh --apply --push # rewrite + force-push origin/main
#
# Pre-flight checklist (the script enforces these):
#   1. Working tree is clean.
#   2. No other host has uncommitted changes (you've checked manually).
#   3. You have `git-filter-repo` installed (pip install git-filter-repo).

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TARGET_PATH="hermes-data/state.sql"

DRY_RUN=1
DO_PUSH=0
for arg in "$@"; do
  case "$arg" in
    --apply) DRY_RUN=0 ;;
    --push)  DO_PUSH=1 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed 's/^# \?//;$d'; exit 0 ;;
    *) printf 'unknown flag: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

if [[ -t 1 ]]; then c_y=$'\033[33m'; c_g=$'\033[32m'; c_r=$'\033[31m'; c_b=$'\033[1m'; c_0=$'\033[0m'
else c_y=''; c_g=''; c_r=''; c_b=''; c_0=''; fi
ok()   { printf '%s✓%s %s\n' "$c_g" "$c_0" "$*"; }
warn() { printf '%s!%s %s\n' "$c_y" "$c_0" "$*"; }
die()  { printf '%s✗%s %s\n' "$c_r" "$c_0" "$*" >&2; exit 1; }
say()  { printf '%s→%s %s\n' "$c_b" "$c_0" "$*"; }

cd "${REPO}"

# --- Pre-flight ---------------------------------------------------------
if ! command -v git-filter-repo >/dev/null 2>&1; then
  die "git-filter-repo not installed. Install with: pipx install git-filter-repo
       (or: pip install --user git-filter-repo)"
fi

if [[ -n "$(git status --porcelain)" ]]; then
  die "working tree is dirty. Commit/stash before running."
fi

# Detect origin URL — needed to re-add after filter-repo strips it.
ORIGIN_URL="$(git remote get-url origin 2>/dev/null || true)"
if [[ -z "${ORIGIN_URL}" ]]; then
  warn "no origin remote configured. Push step (--push) will be a no-op."
fi

# --- Compute the keep set ------------------------------------------------
say "computing keep schedule"

KEEP_FILE=$(mktemp)
trap 'rm -f "${KEEP_FILE}"' EXIT

git log --reverse --format='%H %at' -- "${TARGET_PATH}" \
| python3 -c '
import sys, datetime
today = datetime.datetime.utcnow().date()

commits_by_age = []
for line in sys.stdin:
    sha, ts = line.strip().split()
    d = datetime.datetime.utcfromtimestamp(int(ts)).date()
    age = (today - d).days
    commits_by_age.append((age, d, sha))

def bucket(age):
    """Return (bucket_id) for an age in days. Same bucket → keep one."""
    if age <= 7:    return ("daily", age)
    if age <= 30:   return ("weekly", age // 7)
    if age <= 365:  return ("monthly", age // 30)
    return ("yearly", age // 365)

commits_by_age.sort(key=lambda r: r[0])
seen = set()
keep = []
for age, d, sha in commits_by_age:
    b = bucket(age)
    if b in seen: continue
    seen.add(b)
    keep.append(sha)

for sha in keep:
    print(sha)
' > "${KEEP_FILE}"

KEEP_COUNT=$(wc -l < "${KEEP_FILE}")
TOTAL_COUNT=$(git log --format=%H -- "${TARGET_PATH}" | wc -l)

ok "${KEEP_COUNT} commits to keep, $((TOTAL_COUNT - KEEP_COUNT)) commits will have ${TARGET_PATH} stripped"

# --- Dry-run report -----------------------------------------------------
if (( DRY_RUN )); then
  say "DRY RUN — kept commits with their dates:"
  while IFS= read -r sha; do
    git log -1 --format='  %h  %ai  %s' "${sha}"
  done < "${KEEP_FILE}" | head -25
  if (( KEEP_COUNT > 25 )); then
    echo "  ... ($(( KEEP_COUNT - 25 )) more)"
  fi
  echo
  warn "no changes made. Re-run with --apply to actually rewrite."
  exit 0
fi

# --- Apply --------------------------------------------------------------
warn "rewriting history. This will change every commit hash."
sleep 2

KEEP_PY=$(mktemp --suffix=.py)
trap 'rm -f "${KEEP_FILE}" "${KEEP_PY}"' EXIT

cat > "${KEEP_PY}" <<EOF
import sys
KEEP = set(open('${KEEP_FILE}').read().split())
TARGET = b'${TARGET_PATH}'
def commit_callback(commit, _metadata):
    if commit.original_id.decode() in KEEP:
        return
    commit.file_changes = [fc for fc in commit.file_changes if fc.filename != TARGET]
EOF

git filter-repo --force --commit-callback "$(cat "${KEEP_PY}")"

ok "history rewrite complete"

# git filter-repo strips the origin remote as a safety measure.
if [[ -n "${ORIGIN_URL}" ]]; then
  say "re-adding origin remote (filter-repo removes it as a guard)"
  git remote add origin "${ORIGIN_URL}" 2>/dev/null || true
fi

say "git gc --prune=now (reclaim space from removed blobs)"
git reflog expire --expire=now --all
git gc --prune=now --quiet

NEW_GIT_SIZE=$(du -sh .git | cut -f1)
ok "new .git size: ${NEW_GIT_SIZE}"

if (( DO_PUSH )); then
  if [[ -z "${ORIGIN_URL}" ]]; then
    warn "no origin remote — skipping force-push."
  else
    warn "force-pushing rewritten main to origin (5s grace, Ctrl+C to abort)"
    sleep 5
    git push --force origin main
    ok "force-pushed."
    warn "OTHER HOSTS MUST RE-CLONE OR HARD-RESET — every commit hash changed."
    echo "  On any other host:"
    echo "    cd <repo> && git fetch origin && git reset --hard origin/main"
  fi
else
  warn "DID NOT push. Inspect with 'git log' then run with --apply --push to publish."
fi
