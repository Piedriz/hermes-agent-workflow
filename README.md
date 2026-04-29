# hermes-agent-workflow

A public template for deploying a personal AI assistant stack
(hermes-agent + sidekick PWA + audio bridge) on your own hardware.

Early, working, opinionated. Not a polished product.

## What you get

- **hermes-agent** — the [Nous Research](https://github.com/NousResearch/hermes-agent) Python agent runtime (skills, memory, gateway).
- **sidekick** — a [Progressive Web App (PWA)](https://en.wikipedia.org/wiki/Progressive_web_app) frontend with a Bun proxy and a Python audio bridge for WebRTC voice. Lives in its own repo at [`github.com/jscholz/sidekick`](https://github.com/jscholz/sidekick); this template wires it up.
- **hindsight** — a local memory backend (Postgres + a small FastAPI server) that hermes recalls against.
- **systemd user units** — for the gateway, hindsight server, sidekick proxy, and audio bridge.
- **doctor + sync scripts** — health checks, symlink integrity, optional cron-driven backup of agent state to your fork.
- **`claude-remote` workflow** — a tmux + Claude Code remote-control shell function that lets you drive your agent from claude.ai (web or iOS) on your phone, with warm-start context loaded from a hand-curated `claude-session-history.md` in your fork.
- **sample skills, configs, and an `AGENTS.md`** — sensible defaults you can edit in place.

## Quickstart

Have `claude` (Claude Code) and `git` on your `$PATH`? One line:

```bash
curl -fsSL https://raw.githubusercontent.com/jscholz/hermes-agent-workflow/main/install.sh | bash
```

That clones this repo to `~/code/hermes-agent-workflow` and opens
Claude Code in it. From there, `AGENTS.md` takes over: it walks you
through forking to your own private repo, runs `scripts/bootstrap.sh`
(which prompts for API keys, host name, lat/lon, agent backend),
clones sidekick into `~/code/sidekick/`, builds `uv` venvs, drops
systemd user units into place, and smoke-tests the chain. When it's
done, `https://<host>.local` serves the sidekick PWA and you're
talking to your agent.

Manual variant (no curl, no Claude Code in the loop):

```bash
git clone https://github.com/jscholz/hermes-agent-workflow.git
cd hermes-agent-workflow
./scripts/bootstrap.sh
```

Read the script first; it's short.

## Why fork instead of just using upstream

The repo is a **framework + instance** template. Your fork is your
instance — `hermes.config.yaml`, `AGENTS.md`, `SOUL.md`, memories,
custom skills, and encrypted secrets all live there and never leave
it. Versioning your fork is also your disaster-recovery story: lose
the hardware, get a new machine, clone, run bootstrap, you're back —
including accumulated agent memory and any tweaks you'd made.

You pull updates from this repo as upstream when you want them. See
[`CONTRIBUTING.md`](./CONTRIBUTING.md) for the framework/instance file
ownership rules and the contribution workflow.

## Why everything lives in your fork (the symlink pattern)

`hermes-agent` is a Python package. If you install it via `pip` the
ordinary way, mutable user state — your skills, your accumulated
memories, your config, OAuth tokens — accumulates in `~/.hermes/`,
alongside the package's own files. That makes "version my agent
state" awkward: you don't want to version the whole install, just
your data within it. And you definitely don't want a `pip install -U`
quietly overwriting a memory you've curated for months.

This template solves that with a symlink pattern. The bootstrap
wizard sets up `~/.hermes/` as a tree of symlinks pointing into your
fork of this repo. Edits to skills, configs, or accumulated memories
all land in your repo's directories. `git push` snapshots your full
agent state; `git clone` + `bootstrap.sh` on a new machine restores
it.

Concretely:

- The `skills/` tree in this repo is the live skills directory the
  installed agent reads from. Editing a skill here = editing what the
  running agent uses, immediately.
- Your private fork's `memories/` is what the agent recalls against.
  It grows as the agent learns about you.
- `hosts/<your-host>/` captures per-machine state (Claude Code session
  transcripts, host-local memory snapshots) so multi-machine setups
  don't stomp each other.

Net effect: one `git push` from any machine snapshots that machine's
full agent state. One `git clone` + `bootstrap.sh` on new hardware
restores it.

## Updating hermes-agent

Because skills are versioned in your fork, `pip install -U
hermes-agent` no longer auto-updates them — your repo is the source
of truth. Upstream skill improvements come in via a vendor-branch +
3-way merge: git auto-adopts upstream changes where you haven't
customized, preserves your edits where upstream didn't change, and
surfaces conflicts only on true overlap. See
[`UPGRADES.md`](./UPGRADES.md) for the procedure.

## Encrypted secrets (git-crypt)

Your fork carries real secrets — API keys, OAuth credentials, WhatsApp
session state, the hindsight memory bank dump. To make `git push` to
GitHub safe (even on a "private" repo, where future-you on a different
account or a future collaborator might see the history), those files
are **encrypted at rest** in git history via
[`git-crypt`](https://github.com/AGWA/git-crypt).

Files matching the patterns in `.gitattributes` — `.env`, `auth.json`,
`google_*.json`, `whatsapp/session/**`, `pairing/**`,
`hindsight-data/**` — appear plaintext in your working tree once the
repo is unlocked, but ciphertext in every commit. Anything not listed
is committed plaintext as usual.

**First-time setup, on your first install machine:**

```bash
git-crypt init
git-crypt export-key /tmp/hermes-key   # writes the symmetric key
base64 /tmp/hermes-key                  # save THIS string in a password
                                        # manager + an offline backup
shred -u /tmp/hermes-key
```

**Restoring on a fresh machine:**

```bash
git clone <your-fork>
cd <your-fork>
echo '<base64-key>' | base64 -d | git-crypt unlock -
```

If you lose the key, the encrypted history is unrecoverable. Back it
up in **at least two independent places** — password manager, paper,
offline drive. Adding new file patterns to `.gitattributes` only
encrypts files committed after the change; rotating the key is a full
re-encrypt of history, doable but disruptive.

## Architecture

```
   browser / iOS PWA
         |
         v
  [ sidekick ]            <- PWA + Bun proxy + Python audio bridge
   github.com/jscholz/sidekick
         |
         |  HTTP + WebRTC
         v
  [ hermes-agent ]         <- Python agent runtime
   gateway, skills, plugins, cron
         |
         v
  [ hindsight ]            <- memory backend (Postgres + FastAPI)
```

- **sidekick** is the user-facing surface: PWA, Bun-served proxy at
  `/api/hermes/*`, and an aiortc audio bridge for low-latency voice
  in/out via Deepgram.
- **hermes-agent** runs the actual agent loop, skills, and tool calls.
  It exposes the OpenAI-compatible `/v1/responses` interface that
  sidekick speaks to.
- **hindsight** stores recallable memory; hermes calls it as a skill.
- **This repo** is the glue: config, systemd units, vendored skills,
  the bootstrap wizard, and per-host overrides under `hosts/<host>/`.

For deeper detail on each piece, follow the upstream links — this repo
deliberately doesn't restate them.

## What the sidekick PWA gives you

Once the deployment is up, the PWA at `https://<host>.local` is the
day-to-day surface. A few capabilities worth flagging — see the
[sidekick repo](https://github.com/jscholz/sidekick) for the full
story:

- **Cross-platform session visibility.** The chat drawer shows every
  conversation hermes is tracking — telegram, slack, whatsapp, signal,
  etc. — alongside sidekick chats, with a per-row source badge. Useful
  for monitoring multi-channel agent activity from one pane. The
  composer is read-only when viewing a non-sidekick chat (sidekick
  can't currently send to other platforms).
- **Live drawer updates.** Cross-platform chats refresh via a 5s poll
  while the PWA is foregrounded, plus an immediate refresh on
  tab-focus. Sidekick-owned chats stay live via SSE as before.
- **Web search via Tavily.** When `TAVILY_API_KEY` is set in
  `~/.hermes/.env`, hermes's `web_search` / `web_extract` tools work
  out of the box. See "Requirements" below.
- **Lazy chat creation.** "New chat" no longer mints an empty stub —
  the chat materializes on first send, so the drawer never shows
  empty rows.
- **Atomic send with retry.** If a send fails to reach the agent, the
  bubble flips to a `.failed` state with Retry / Dismiss controls
  rather than leaving a delivered-looking message that never landed.
- **First-message snippet fallback.** Drawer rows show a snippet of
  the first user message until hermes generates a real title.

## Requirements

- **OS**: Linux (Pi 5 / Ubuntu / Debian validated). macOS support is
  pending — aiortc + ffmpeg should install cleanly via Homebrew, but
  end-to-end validation hasn't happened yet. File issues.
- **Python**: 3.11 or newer.
- **`uv`**: install from [astral.sh/uv](https://docs.astral.sh/uv/).
- **`git`**, **`ffmpeg`**, **`tmux`**, and **`git-crypt`** (for encrypted secrets — see "Encrypted secrets" below) on `$PATH`. The curl installer will check for these and tell you how to install any that are missing; the rest of the installer is idempotent so you can re-run it after.
- **Bun**: for the sidekick proxy. Install from [bun.sh](https://bun.sh).
- **API keys**:
  - **Deepgram** for STT/TTS in the audio bridge.
  - An **LLM provider key** — OpenRouter, Anthropic, OpenAI, or a
    local backend; configure per `hermes.config.yaml`.
  - **Tavily** (optional) — set `TAVILY_API_KEY` in `~/.hermes/.env`
    to enable hermes's `web_search` / `web_extract` tools. Free tier
    is 1000 requests/month; sign up at [tavily.com](https://tavily.com).
    Without it, `web_search` is a no-op.

The bootstrap wizard prompts for the required ones; Tavily is
optional and can be added to `~/.hermes/.env` after the fact.

## Status

**v0.1, early.** Built for Jonathan's Pi 5 deployment ("blueberry") and
opening to a small group of contributors. Expect:

- Sharp edges in the bootstrap wizard, especially on macOS.
- A few framework/instance boundaries that are fuzzier than they should
  be — the file-ownership table is the source of truth, and we're
  still tightening the implementation to match.
- WebRTC audio behavior that's been validated on ARM Linux but not yet
  bike-tested on Mac.

Issues, PRs, and "this didn't work for me" reports are all welcome.

## License

[Apache License 2.0](./LICENSE) — matching the sidekick repo.

## Acknowledgments / related repos

- [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) — upstream agent runtime.
- [jscholz/sidekick](https://github.com/jscholz/sidekick) — the PWA + proxy + audio bridge.
- [jscholz/hermes-agent](https://github.com/jscholz/hermes-agent) — Jonathan's fork, where local patches land before they're proposed upstream.
