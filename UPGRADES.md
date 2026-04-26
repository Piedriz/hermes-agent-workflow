# Updating hermes-agent

This doc covers the workflow for picking up upstream improvements to
[`hermes-agent`](https://github.com/NousResearch/hermes-agent) — both
the package code (handled by `pip install -U`) and the bundled skill
catalog (handled by the vendor-branch pattern below).

For local **patches** layered on top of upstream — your own and others'
— see [`CONTRIBUTING.md`](./CONTRIBUTING.md) and
[`PATCHES.md`](./PATCHES.md). Patches and skill-vendoring are
independent concerns.

## The two layers that move

When upstream ships a new `hermes-agent` release, two things change:

1. **The Python package** — the agent runtime, gateway, plugins, tool
   adapters, etc. Lives inside the venv at
   `~/.hermes/hermes-venv/lib/.../hermes_agent/`. `pip install -U
   hermes-agent` updates this in-place; nothing in your fork moves.

2. **The bundled skills catalog** — `apple/`, `productivity/`,
   `software-development/`, the 50+ optional skills, etc. Upstream
   ships these inside the package distribution, and on a fresh install
   bootstrap copies them into your fork's `skills/` directory. Once
   they're in your fork, **your repo is the source of truth** —
   `pip install -U` does not touch your `skills/` tree.

The symlink pattern is what makes (2) work the way you want: your
edits to a skill stay yours; the agent reads what's in your repo, not
what's in the package.

The cost is that upstream skill improvements no longer arrive
automatically. You need a deliberate merge.

## The vendor-branch pattern

Standard git vendoring trick. Maintain a separate branch in your fork
that mirrors upstream's skill tree exactly, never edited by hand.
After each upgrade, merge that branch into `main`; git's 3-way merge
sorts out who-changed-what.

### One-time setup

From a fresh-install machine, with a working hermes-agent venv:

```bash
cd <your-fork>
git checkout --orphan vendored-skills
git rm -rf .

# Copy bundled + optional skills from the live install. Adjust the path
# if your venv is somewhere different.
HERMES_PKG=$(~/.hermes/hermes-venv/bin/python -c "import hermes_agent, os; print(os.path.dirname(hermes_agent.__file__))")
cp -r "${HERMES_PKG}/skills"          ./skills
cp -r "${HERMES_PKG}/optional-skills" ./optional-skills

git add skills optional-skills
git commit -m "vendored-skills: import from hermes-agent v$(~/.hermes/hermes-venv/bin/hermes --version)"
git tag "vendored-v$(~/.hermes/hermes-venv/bin/hermes --version)"
git checkout main
```

### After each `pip install -U hermes-agent`

```bash
cd <your-fork>

# 1. Refresh the vendor branch from the new install tree.
git checkout vendored-skills
HERMES_PKG=$(~/.hermes/hermes-venv/bin/python -c "import hermes_agent, os; print(os.path.dirname(hermes_agent.__file__))")
rm -rf skills optional-skills
cp -r "${HERMES_PKG}/skills"          ./skills
cp -r "${HERMES_PKG}/optional-skills" ./optional-skills
git add -A skills optional-skills
git commit -m "vendored-skills: refresh from hermes-agent v$(~/.hermes/hermes-venv/bin/hermes --version)"
git tag "vendored-v$(~/.hermes/hermes-venv/bin/hermes --version)"

# 2. Merge into main. 3-way merge handles the diff.
git checkout main
git merge vendored-skills
```

### What git does with the merge

The merge base is the common ancestor of `main` and `vendored-skills`
— the last vendored snapshot you tracked. Against that base:

- **Files upstream changed, you didn't** → upstream wins. Auto-merged.
- **Files you changed, upstream didn't** → your edits stay. Auto-merged.
- **Both sides changed the same file** → conflict. Resolve by hand.

The conflicts are usually small (a fixed bug, a renamed option). If
the conflict is in a skill you customized heavily, your version
typically wins; if in a skill you've never touched, take upstream.

### What does NOT go on the vendor branch

- **Code** (`gateway/`, `agent/`, `plugins/`) — `pip` manages this.
- **Templates that got customized once** (`cli-config.yaml.example`,
  upstream's `AGENTS.md`) — diverged too far for 3-way merge to add
  value.
- **Locally patched files** like `gateway/platforms/whatsapp.py` or
  `scripts/whatsapp-bridge/bridge.js` — these belong in
  [`patches/hermes-agent/`](./patches/hermes-agent/), not in vendored
  skills. See [`CONTRIBUTING.md`](./CONTRIBUTING.md).

### Pending tooling

A `scripts/refresh-vendored-skills.sh` to wrap the "after each
upgrade" steps above is planned but not yet implemented. For now run
the commands by hand. Treat hermes upgrades as deliberate events, not
something you do casually before bed.

## Other things to check after upgrading

- **`scripts/doctor.sh`** — runs the symlink integrity check + sanity
  pings the gateway. Run it post-merge.
- **`pip install -U hindsight-api-slim`** — separate package, separate
  upgrade cadence. Check release notes; the schema sometimes moves.
- **systemd unit reload** — if upstream changed the recommended
  service shape, regenerate from `systemd/*.service.template` via
  `scripts/bootstrap.sh` (which is idempotent and won't clobber
  customizations).

## When you hit something the doc doesn't cover

Open an issue against
[`jscholz/hermes-agent-workflow`](https://github.com/jscholz/hermes-agent-workflow/issues)
with what you ran, what you expected, and what you got. Upgrade
mishaps are exactly the kind of thing that should turn into doc
improvements.
