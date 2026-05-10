# workspace/

Personal documents the agent can read and edit. Drop your notes,
drafts, scratch files, anything you want versioned alongside your
agent state.

`workspace/documents/` is the conventional spot. The agent reaches
files here via the `terminal` and `file` skills.

If you have sensitive content here you want encrypted at rest in
git, add to `.gitattributes`:

    workspace/documents/**  filter=git-crypt diff=git-crypt

…then `git-crypt status -f` to migrate. Plaintext on disk,
encrypted in history.

Note: `workspace/` is NOT symlinked into `~/.hermes/`. It's just
versioned alongside your agent state for convenience. If you want
the agent to default to working in this directory, set
`terminal.cwd: ~/code/<your-fork>/workspace` in `~/.hermes/config.yaml`.
