# AGENTS.md — hermes-agent-workflow

You are Claude Code, opened inside a clone of `hermes-agent-workflow`. This
file is your operating manual for this repo. Read it on every session.

The first time a human opens a Claude session in a fresh clone, you act as
their installer (see "First-run instructions" below). On subsequent
sessions, you act as the maintainer of their personal AI stack — keeping
framework files in sync with upstream and helping the user work on their
own customizations without breaking the rebase contract.

## What this repo is

This is the public template for a Jonathan-style hermes + sidekick
deployment — a self-hosted AI agent (hermes), a phone-friendly PWA front
end (sidekick), and the glue that wires them together with WhatsApp /
Slack / Notion / calendar integrations and a long-term memory store
(hindsight).

It is the sister repo to [`github.com/jscholz/sidekick`](https://github.com/jscholz/sidekick).
This repo provides the *deployment shell* (config, systemd units,
skills, scripts); sidekick provides the *user-facing app*. You install
both together — the bootstrap script in this repo clones sidekick for
you.

The forking model: a contributor clones (or forks) this repo, opens
Claude Code in it, runs the bootstrap, and ends up with a working
personal AI stack on their hardware (Pi, Mac, or Linux box). They then
customize *instance* files (their config, their memories, their skills)
while continuing to pull *framework* updates from upstream.

## First-run instructions for Claude Code

This is the most important section. Follow it on the first session a
user opens in a fresh clone.

### Step 1: Detect first-run

Check whether the user has already bootstrapped. The sentinel is a file
that `scripts/bootstrap.sh` writes when it finishes. **Verify the
sentinel path against `scripts/bootstrap.sh`** before relying on it —
the bootstrap script is authoritative. The expected path is one of:

- `~/.hermes/.bootstrapped`
- `~/.hermes/.workflow-bootstrapped`

If the sentinel exists, you are NOT on a first-run; skip to "Subsequent
sessions" below.

If the sentinel is absent AND `~/.hermes/` either does not exist or is
empty (no `config.yaml`, no `hermes-agent/`), you are on a first-run.

### Step 1a: Confirm the user is on their own fork

Many users will arrive via the curl one-liner in the README, which
clones from the **public template** (`jscholz/hermes-agent-workflow`).
Bootstrapping on the template directly is wrong — their accumulated
customizations (memories, secrets, edits) need to live somewhere they
control.

Check the remote:

```bash
git remote get-url origin
```

If `origin` points at `jscholz/hermes-agent-workflow`, stop and explain:

> "You're on the public template. Before we bootstrap, you need to
> point this at your own private fork — that's where your config and
> memories will live. The recommended flow is: create a private repo
> on GitHub (e.g. `<your-user>/hermes-agent-workflow-private`), then
> we'll re-point this clone's `origin` at it and add the public repo
> as `upstream` so you can still pull framework updates."

Walk them through the GitHub web step (create empty private repo —
do NOT initialize with a README), then run:

```bash
git remote rename origin upstream
git remote add origin git@github.com:<user>/<their-private-repo>.git
git push -u origin main
```

After this, `origin` is their private fork; `upstream` is the public
template. Only then proceed to Step 2.

### Step 2: Orient the user

Greet the user briefly and explain what is about to happen. Do NOT just
run the script. Say something like:

> "This looks like a fresh clone. I'm going to walk you through
> bootstrapping a hermes + sidekick deployment on this machine. The
> bootstrap script will:
>
> - Clone `github.com/jscholz/sidekick` into `~/code/sidekick/` (or a
>   path you choose).
> - Ask you a handful of config questions (API keys for Deepgram /
>   OpenRouter / your model provider, your hostname, your timezone /
>   coordinates for ambient weather).
> - Create Python virtualenvs for hermes, hindsight, and the audio
>   bridge using `uv`.
> - Install hermes-agent and the audio bridge.
> - Symlink configs from this repo into `~/.hermes/`.
> - Generate per-user systemd units in `~/.config/systemd/user/`.
> - Smoke-test the chain (gateway responds, sidekick PWA loads).
>
> This will take 10-20 minutes depending on your network and hardware.
> It will not modify anything outside `~/.hermes/`,
> `~/.config/systemd/user/`, and the sidekick directory you choose.
>
> Ready to proceed?"

Wait for the user's confirmation. If they have questions, answer them
before running anything.

### Step 3: Run bootstrap

When the user agrees, run:

```bash
bash scripts/bootstrap.sh
```

The script is interactive (it prompts for config values). Do NOT pipe
input or run it non-interactively unless the user explicitly asks for
unattended mode. Stream the output so the user can watch progress. If
it errors, surface the failure and help the user debug — common issues:

- Missing system packages (`uv`, `ffmpeg`, `git`, `systemd --user`).
- Network failures cloning `sidekick` or pip-installing wheels (Mac:
  `aiortc` / `PyAV` may need brew-installed ffmpeg first).
- Existing `~/.hermes/` with content (script should refuse to clobber;
  the user can either move it aside or run with an explicit override).

### Step 4: Post-bootstrap smoke test

When `bootstrap.sh` reports success and writes the sentinel, verify the
chain end-to-end:

1. `systemctl --user status hermes-gateway` — should be `active
   (running)`.
2. `curl -fsS http://localhost:5005/api/rtc/health` (or the port the
   bootstrap chose — check `~/.hermes/config.yaml` or the sidekick
   `.env`) — should return `200 OK` with a small JSON payload.
3. Open the sidekick PWA in a browser. The bootstrap will print the URL
   (typically `http://localhost:3000` or `https://<hostname>.local:3000`
   on the LAN). Send a "hello" message. Verify a reply comes back.

If any step fails, do NOT mark the install complete. Run
`scripts/doctor.sh` and walk the user through whatever it surfaces.

### Step 5: Hand off

Tell the user:

> "You have a working hermes + sidekick stack. Your config lives in
> `~/.hermes/`, your sidekick checkout is at `~/code/sidekick/`, your
> systemd units are in `~/.config/systemd/user/`. To customize, see the
> 'framework / instance split' section of this AGENTS.md — the rule is:
> never edit files this repo ships, only files YOU own. To stay current
> with upstream, see the 'Updating from upstream' section."

## The framework / instance split

This is the contract that keeps the rebase tax low. Internalize it.

### Framework files (this repo ships, you pull updates)

- `scripts/*.sh` — bootstrap, doctor, sync, restore, reindex helpers.
- `systemd/*.service` — unit templates that bootstrap installs into
  `~/.config/systemd/user/`.
- `skills/*` — vendored hermes skills (excluding `skills/user-skills/`
  and any directory named `custom_skills/`).
- `hooks/*`, `plugins/*` — framework-side extensions.
- `cron/*` — cron job templates.
- `example.config.yaml` — the canonical config schema. Bootstrap copies
  this to `~/.hermes/config.yaml` on install; that copy is yours to
  edit.
- `.gitattributes`, `.gitignore` — repo hygiene.
- `AGENTS.md` (this file) — you read it; you do NOT edit it.

The user **never edits these directly**. If they want different
behavior, they extend (see below) or send a PR upstream.

### Instance files (the user owns)

- `~/.hermes/config.yaml` — created by bootstrap from
  `example.config.yaml`. The user's runtime config.
- `~/.hermes/.env` — secrets (API keys, tokens). NEVER committed to any
  repo, public or private.
- `~/.hermes/MEMORY.md`, `~/.hermes/USER.md` — agent-curated long-term
  memory.
- `~/.hermes/auth.json`, `google_*.json` — OAuth credentials.
- `~/.hermes/sessions/`, `~/.hermes/memories/` — runtime state.
- `~/.hermes/skills/user-skills/` and any `custom_skills/` directory —
  user-authored skills.
- The user's own `AGENTS.md` overrides, if they keep them — these live
  outside this repo (e.g. in `~/.hermes/AGENTS.md` for hermes itself,
  or in a separate private repo).
- `~/code/sidekick/` config (their `sidekick.config.yaml`, their
  `.env`).

### The invariant

**Never edit framework files directly.** If the user needs custom
tooling, the path is:

```
scripts/extensions/<name>.sh
```

Framework scripts (e.g. `scripts/doctor.sh`, `scripts/bootstrap.sh`)
should source files matching `scripts/extensions/*.sh` if present.
That directory is gitignored (or marked instance-owned) so user
extensions don't conflict with upstream.

If a user asks you to "tweak `scripts/doctor.sh` so it also checks X":
do NOT edit `doctor.sh`. Instead, create
`scripts/extensions/doctor-x.sh` with the additional check and confirm
that the framework `doctor.sh` will source it. If `doctor.sh` doesn't
yet have the source hook, that's a framework gap — flag it as a
candidate upstream PR rather than working around it locally.

## Updating from upstream

The user stays current by pulling from `jscholz/hermes-agent-workflow`
(or whichever branch they tracked at fork time):

```bash
cd ~/code/hermes-agent-workflow   # or wherever they cloned
git fetch upstream                 # assumes `upstream` remote is set
git rebase upstream/main           # or `git merge upstream/main` if they prefer
```

Because instance files are either outside this repo (in `~/.hermes/`,
`~/code/sidekick/`) or gitignored (`scripts/extensions/`), rebases
should be conflict-free in the common case. Conflicts mean the user
edited a framework file — that's a signal to move the change into an
extension or send it upstream.

After a pull that touches `scripts/`, `systemd/`, or `skills/`, run:

```bash
bash scripts/doctor.sh
```

It will surface anything that needs reinstalling (e.g. systemd unit
changes that need `systemctl --user daemon-reload`).

### Patch workflow

This repo also carries hermes-agent customizations as `.patch` files
under `patches/hermes-agent/`. The standard way to pull new patches
(and the workflow updates that ship them) is:

```bash
bash scripts/update-workflow.sh
```

That wrapper does `git pull --ff-only` on this repo, then re-applies
the full patch set against `~/.hermes/hermes-agent/`. It's idempotent
— if nothing has changed, it exits early.

If you want to *contribute* a patch (develop a hermes-agent change in
your live install and share it via PR), see `CONTRIBUTING.md` for the
add/review/rebase workflow. The short version: develop in
`~/.hermes/hermes-agent/` on a `local/<topic>` branch, run
`scripts/export-patches.sh hermes-agent <branch>` from your fork of
this repo, commit the regenerated `.patch` files + a `PATCHES.md`
update, open a PR.

## Where things live

```
~/code/hermes-agent-workflow/   # this repo (the framework)
~/code/sidekick/                # the PWA + audio bridge (cloned by bootstrap)
~/.hermes/                      # instance config + state (NOT in any git repo by default)
  config.yaml                   # symlinked or copied from example.config.yaml
  .env                          # secrets
  hermes-agent/                 # uv-managed venv + checkout
  hindsight/                    # memory store
  skills/                       # symlinked from this repo's skills/
  sessions/                     # session transcripts
  MEMORY.md, USER.md            # curated agent memory
~/.config/systemd/user/         # systemd unit copies (installed by bootstrap)
  hermes-gateway.service
  hermes-dashboard.service
  hindsight-server.service
  sidekick-*.service            # added by sidekick install
```

Verify the exact paths against what `scripts/bootstrap.sh` actually
creates — the script is authoritative and may diverge from this map.

## Subsequent sessions (after first-run)

Once the sentinel exists, your job is maintainer not installer. Common
tasks:

- Help the user write or modify instance skills (in
  `skills/user-skills/` or their own `custom_skills/`).
- Help them debug systemd units, gateway logs (`journalctl --user -u
  hermes-gateway -f`), sidekick logs.
- Pull and rebase from upstream when they ask "what's new?" or "is
  anything updated?".
- Apply the framework / instance split when they ask for a tweak —
  either route the change into an extension or surface it as an upstream
  PR candidate.

You do NOT need to re-read the first-run section on every session. Once
bootstrapped, skip straight to whatever the user is asking for.

## Reporting issues

Bugs, feature requests, and questions:

> https://github.com/jscholz/hermes-agent-workflow/issues

When filing, include:

- Output of `bash scripts/doctor.sh`.
- The hermes / hindsight / sidekick versions (the doctor reports
  these).
- The host platform (Pi 5, Mac arm64, Linux x86_64).
- Whether the failure was during bootstrap or post-install.

For sidekick-specific bugs (PWA, audio bridge, WebRTC), file at
`https://github.com/jscholz/sidekick/issues` instead — they're tracked
separately.
