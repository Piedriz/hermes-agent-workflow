# memories/

Hermes auto-memory files. The agent reads `MEMORY.md` and `USER.md`
on every session start and updates them as it learns about you.

You can edit these files directly — the agent picks up changes on
the next session start. Be sparing about adds; the agent works
better with curated content than a wall of facts.

`~/.hermes/memories/` is symlinked to this directory by
`scripts/bootstrap.sh`, so edits land in your fork automatically.

If you want these encrypted at rest in your fork, add to
`.gitattributes`:

    memories/**  filter=git-crypt diff=git-crypt

…then `git-crypt status -f` to migrate existing files. They'll be
encrypted in git history while staying plaintext on disk.
