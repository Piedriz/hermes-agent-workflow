# hermes-agent-workflow

A public template for deploying a personal AI assistant stack
(hermes-agent + sidekick PWA + audio bridge) on your own hardware.

Early, working, opinionated. Not a polished product.

## What you get

- **hermes-agent** — the [Nous Research](https://github.com/NousResearch/hermes-agent) Python agent runtime (skills, memory, gateway).
- **sidekick** — a PWA frontend with a Bun proxy and a Python audio bridge for WebRTC voice. Lives in its own repo at [`github.com/jscholz/sidekick`](https://github.com/jscholz/sidekick); this template wires it up.
- **hindsight** — a local memory backend (Postgres + a small FastAPI server) that hermes recalls against.
- **systemd user units** — for the gateway, hindsight server, sidekick proxy, and audio bridge.
- **doctor + sync scripts** — health checks, symlink integrity, optional cron-driven backup of agent state to your fork.
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

The repo is a **framework + instance** template:

- **Your fork is your instance.** Your `hermes.config.yaml`,
  `AGENTS.md`, `SOUL.md`, memories, custom skills, and encrypted
  secrets all live in your fork and never leave it. Versioning your
  fork is also your disaster-recovery story: lose the hardware, get
  a new machine, clone the fork, run bootstrap, you're back —
  including accumulated agent memory and any tweaks you'd made.
- **Upstream stays the framework.** Bootstrap scripts, doctor
  scripts, systemd units, vendored skills, and the example config
  template are upstream-owned. When the framework improves, you
  `git pull` into your fork and merge.

The invariant: **don't edit framework files in your fork.** Add new
behavior in `scripts/extensions/<custom>.sh` or in
`skills/user-skills/<your-skill>/`. See `AGENTS.md` for the full
file-ownership table.

This is the same shape as upstream `NousResearch/hermes-agent` →
`jscholz/hermes-agent` (a fork that carries local patches) → your
working tree. Three tiers, each pulling from the one above.

## Why everything lives in your fork (the symlink pattern)

`hermes-agent` reads from `~/.hermes/` at runtime — that's where
configs, skills, memories, and per-host state are expected to live.
The bootstrap wizard sets up `~/.hermes/` as a tree of **symlinks
into this repo**, so when hermes writes a memory or you tweak a skill
in place, the change actually lands inside your fork. Commit, push,
and your full agent state is versioned.

This is foundational to how the workflow operates:

- The `skills/` tree in this repo is the live skills directory the
  installed agent reads from. Editing a skill here = editing what
  the running agent uses, immediately.
- Your private fork's `memories/` is what the agent recalls against.
  It grows as the agent learns about you.
- `hosts/<your-host>/` captures per-machine state (Claude Code session
  transcripts, host-local memory snapshots) so multi-machine setups
  don't stomp each other.

Net effect: a single `git push` from any machine snapshots that
machine's full agent state. A single `git clone` + `bootstrap.sh` on
new hardware restores it.

### Pulling skill updates from upstream hermes-agent

The wrinkle this model creates: `pip install -U hermes-agent` no
longer auto-updates your skill set. Upstream ships bundled skill
groups (`apple/`, `productivity/`, `software-development/`, ...) inside
the package itself, and at first-install time bootstrap copies them
into your fork's `skills/` directory. Once they're versioned in your
fork, your repo is the source of truth — pip-upgrading the package
won't touch your `skills/` tree.

When upstream ships skill improvements you want, the recommended flow
is the **vendor-branch pattern**:

1. Maintain a `vendored-skills` branch that mirrors a clean snapshot
   of `~/.hermes/hermes-agent/skills/` (and `optional-skills/`) from a
   given hermes-agent release. Tag commits with the version.
2. After `pip install -U hermes-agent`, refresh the vendor branch from
   the new install tree, commit + tag.
3. `git merge vendored-skills` into main — git's 3-way merge auto-adopts
   upstream changes where you haven't customized, preserves your edits
   where upstream didn't change, and surfaces conflicts only on true
   collisions.

Tooling for this is pending (`scripts/refresh-vendored-skills.sh` is
the planned home). For now, treat hermes upgrades as deliberate events
and merge skill changes by hand. See the workflow notes in
`CONTRIBUTING.md` for the latest state.

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

## Requirements

- **OS**: Linux (Pi 5 / Ubuntu / Debian validated). macOS support is
  pending — aiortc + ffmpeg should install cleanly via Homebrew, but
  end-to-end validation hasn't happened yet. File issues.
- **Python**: 3.11 or newer.
- **`uv`**: install from [astral.sh/uv](https://docs.astral.sh/uv/).
- **`git`**, **`ffmpeg`**, and **`git-crypt`** (for encrypted secrets — see "Encrypted secrets" below) on `$PATH`.
- **Bun**: for the sidekick proxy. Install from [bun.sh](https://bun.sh).
- **API keys**:
  - **Deepgram** for STT/TTS in the audio bridge.
  - An **LLM provider key** — OpenRouter, Anthropic, OpenAI, or a
    local backend; configure per `hermes.config.yaml`.

The bootstrap wizard prompts for these.

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
