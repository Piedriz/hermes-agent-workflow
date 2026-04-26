# Patches

Local patches the workflow carries on top of upstream
[`NousResearch/hermes-agent`](https://github.com/NousResearch/hermes-agent).
They are applied at install/update time by `scripts/apply-patches.sh`
against a clean checkout pinned to `origin/main`.

See `CONTRIBUTING.md` for the full add/review/pull workflow. The
patches below are stored as `git format-patch` output; they are
plaintext and human-reviewable in PR diffs.

## Active patches (applied in order)

| File | What it does | Why not yet upstream | Upstream candidate? |
|------|--------------|----------------------|---------------------|
| `0001-whatsapp-prepend-sender-identity-to-group-messages.patch` | Prepends a `sender=<jid>` prefix to inbound group messages so the agent can address replies and disambiguate speakers in a group thread. | No PR opened yet; bundle plan calls for a focused "group identity prefix" PR. | Yes — useful for any group-aware bot. |
| `0002-whatsapp-bridge-allow-fromMe-isGroup-messages-throug.patch` | Lets the WhatsApp bridge forward `fromMe`+`isGroup` messages into the gateway (previously dropped) so the agent can see its own outbound traffic for context and react to it. | No PR opened yet; pairs with the react-tool bundle. | Yes — pairs with react tool. |
| `0003-whatsapp-bridge-add-react-endpoint-expose-fromMe-in-.patch` | Adds a `POST /react` endpoint to the WhatsApp bridge and exposes `fromMe` in event payloads so the agent can react to messages by ID. | No PR opened yet; pairs with the react-tool bundle. | Yes — pairs with react tool. |
| `0004-whatsapp-add-react_to_message-tool-adapter-method.patch` | Adds a `react_to_message` tool + adapter method so the agent can react with an emoji to a specific message id. | No PR opened yet; clean feature PR queued. | Yes — clean feature add. |
| `0005-whatsapp-include-msg-id-in-group-prefix-for-react_to.patch` | Includes `msg=<id>` in the group message prefix so the react-tool has a stable id to target. | No PR opened yet; pairs with react tool. | Yes — pairs with react tool. |
| `0006-gateway-suppress-busy-ack-chat-message-on-WhatsApp.patch` | Suppresses the "I'm busy, hang on" auto-ack chat message on the WhatsApp platform — for chat surfaces it's noise, not signal. | No PR opened yet; queued as a focused bug-fix PR. | Yes — bug fix, fully general. |
| `0007-whatsapp-per-group-mute-with-canned-reply-for-dev-si.patch` | Adds per-group mute config (`whatsapp.group_muted` + `whatsapp.muted_reply`) for silencing the bot in dev/test groups while still acknowledging the message. | No PR opened yet; queued as a small standalone PR. | Yes — clean general feature. |
| `0008-tools-add-video_analyze_tool-gemini-3-flash-via-open.patch` | Adds a `video_analyze` tool (Gemini 3 Flash via OpenRouter, with ffmpeg keyframe fallback) plus auto-enrichment for inbound video media in the gateway. | No PR opened yet; queued as a feature PR. | Yes — clean feature add. |

Patches that touched the WebRTC subsystem are intentionally **not**
included — the WebRTC stack moved out of hermes-agent into the
sidekick repo (`audio-bridge/`), and the in-tree removal commit is
pure subtraction, not portable across upstream rebases.

## How patches stay current

When upstream `hermes-agent` moves, a patch may stop applying cleanly.
The contributor who originated the patch is responsible for refreshing
it: rebase the source branch in their `~/.hermes/hermes-agent/`
checkout onto the new `origin/main`, then re-export via
`scripts/export-patches.sh hermes-agent <branch>` and open a PR with
the regenerated `.patch` files.

If a patch silently breaks (still applies, but the surrounding code
was renamed/moved underneath it), the next `apply-patches.sh` run
fails loudly via `git am` — there's no way for the patch to land
with a stale assumption baked in.
