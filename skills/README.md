# skills/

The hermes skills tree, symlinked from `~/.hermes/skills/`.

This directory holds two layers of content:

1. **Bundled skill groups** (`apple/`, `productivity/`, `email/`,
   `creative/`, etc.) — vendored from upstream `hermes-agent` at
   install time. Updated via `tools/skills_sync.py` on every hermes
   upgrade.

2. **Your custom skills** — typically under `user-skills/<name>/`,
   though you can drop them anywhere in the tree. Hermes discovers
   them by walking the directory looking for `SKILL.md` files.

## How skills survive upstream upgrades

Hermes maintains a manifest at `.bundled_manifest` recording the
MD5 of each bundled skill at last sync. On `pip install -U
hermes-agent` (or any other invocation of `tools/skills_sync.py`):

- **Untouched skill** (current local hash matches manifest):
  refresh from new bundled version, update manifest.
- **Customized skill** (current local hash differs from manifest):
  SKIP — your version is preserved as-is.
- **New skill in upstream**: copy in.
- **Skill you deleted** (in manifest, absent on disk): respect
  deletion, don't re-add.

Per-skill granularity, NOT per-file or per-line. **Touch any file
in a skill, and the entire skill becomes "yours"** for sync
purposes — `skills_sync` will skip the whole directory on every
future sync until you reset it. There is **no merge logic**;
the choice is binary.

To re-seed a customized skill from upstream (losing your edits):

    hermes skills reset <skill-name>

For the full mechanism, see the README at the repo root, "How
skills survive upstream upgrades."
