#!/usr/bin/env bash
# List all WhatsApp groups the bot account is a member of, with names + JIDs.
# Flags groups that are NOT currently in the allowlist so you can spot
# the candidates to add when setting up a new test group.
#
# Usage:
#   bash scripts/wa-groups.sh           # plain table
#   bash scripts/wa-groups.sh --new     # only un-whitelisted groups
#
# Requires the WhatsApp bridge to be running on 127.0.0.1:3000 (it's
# part of hermes-gateway; if hermes-gateway is up, the bridge is too).
set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
HERMES="${HERMES:-$HOME/.hermes}"
CONFIG="${CONFIG:-$REPO/hermes.config.yaml}"
SESSION="${SESSION:-$HERMES/whatsapp/session}"
BRIDGE="${BRIDGE:-http://127.0.0.1:3000}"

# Sanity check
if ! curl -sfS --max-time 2 "${BRIDGE}/health" >/dev/null 2>&1; then
  echo "WhatsApp bridge not reachable at ${BRIDGE}." >&2
  echo "Is hermes-gateway running? Try: systemctl --user status hermes-gateway" >&2
  exit 1
fi

# Pull the current allowlist. Group JIDs only appear in group_allow_from
# in this config, so a plain grep is sufficient (no need for a YAML
# parser dance — the awk-range trick had an off-by-one with the
# group_allow_from: line itself matching the end pattern).
allowlist=$(grep -oE '120363[0-9]+@g\.us' "${CONFIG}" | sort -u || true)

# Walk the baileys session sender-key files for the canonical list of groups
# the bot account is a member of (groups don't appear here unless someone has
# sent at least one encrypted message in them since the session was created).
groups=$(ls "${SESSION}" 2>/dev/null \
  | grep -oE '120363[0-9]+@g\.us' \
  | sort -u)

[[ -z "${groups}" ]] && { echo "no groups found in baileys session — bridge may be uninitialized." >&2; exit 1; }

new_only=false
[[ "${1:-}" == "--new" ]] && new_only=true

printf '  %-50s  %-30s  %s\n' "GROUP NAME" "JID" "ALLOWLISTED?"
printf '  %-50s  %-30s  %s\n' "----------" "---" "------------"
while IFS= read -r jid; do
  name=$(curl -sfS --max-time 3 "${BRIDGE}/chat/${jid}" 2>/dev/null \
    | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('name','?'))" 2>/dev/null \
    || echo "?")

  if echo "${allowlist}" | grep -qx "${jid}"; then
    status="✅ yes"
    [[ "${new_only}" == "true" ]] && continue
  else
    status="❌ no"
  fi

  # Truncate long names so the table stays one-line-per-group
  name_short=$(printf '%-50s' "${name:0:50}")
  printf '  %-50s  %-30s  %s\n' "${name_short}" "${jid}" "${status}"
done <<< "${groups}"

echo ""
echo "To add an unwhitelisted group: edit ${CONFIG}, add the JID under"
echo "the whatsapp.group_allow_from list, then 'systemctl --user restart hermes-gateway'."
