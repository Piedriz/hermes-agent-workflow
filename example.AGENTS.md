# AGENTS.md — Tool Hints

This file is auto-loaded into every hermes session. Your `SOUL.md`
tells the agent WHO it is; this file tells it WHICH tools to reach
for when you ask for something. Hermes's skill registry tells it
HOW each tool works in detail — this file just helps it pick the
right one fast.

Keep this file concise (under ~150 lines). Edit it to match your
own setup — the patterns below are starters, not prescriptions.
The agent self-updates this file at session-end if it discovers a
better invocation pattern (see **Self-update** at the bottom).

## Tool Selection — by request shape

### Calendar / scheduling
- **"What's on my calendar", "do I have a meeting"** → `google-workspace`
  skill → `calendar list --max N` (events only, not the full calendar list).
  For "tomorrow" / "this week" filtering, check the skill's calendar-list
  flags for `--time-min` / `--time-max` (ISO-8601 dates).
- **"Schedule / create event"** → `google-workspace calendar create` —
  this is an external action, confirm before committing.
- **Delete / move** → confirm twice; calendar deletes don't trash-bin.

### Email
- Adapt this section to your email setup.
- If you're on a single Gmail account, the bundled
  `productivity/google-workspace` skill handles it.
- If you're on multiple accounts, look at the `email/gog` user-skill
  pattern — `gog --account <email> gmail ...`.
- **Drafts-first**. Default for any composed email is `drafts create`.
  Only `send` after the user explicitly says "send it" / "fire it
  off" / "ship it". Generic "yes" / "ok" / "do it" after you propose
  a message means "draft it", not "send it".

### Memory (hindsight)
- The agent calls `recall` automatically when it needs context. If
  you ask "do you remember X" or "what did I tell you about Y", it
  should fall through to recall.
- `MEMORY.md` and `USER.md` files in `memories/` are auto-loaded
  per session. Edit them directly to nudge the agent's persistent
  state. The agent updates them as it learns.

### Web search
- `web_search` skill if `TAVILY_API_KEY` is set. Quick fact-checks,
  citations, current events.
- For deep dives, prefer the `research` skill family (cross-reference,
  source provenance) over single web_search calls.

### Code / terminal
- `terminal` for shell commands. Long-running jobs go via the
  background-process system (see hermes docs).
- `python_runner` for ad-hoc Python (data shaping, quick parsing).
- `kanban` for breaking large tasks into trackable chunks.

### Documents
- `notion`, `obsidian`, `apple-notes` skills for note systems.
- `google-workspace` for Docs / Sheets / Drive.
- Files in `workspace/documents/` are direct-readable from terminal.

## Routing rules to add yourself

Most users have multiple email accounts, multiple chat platforms
(Slack, Telegram, WhatsApp), and a personal preference for which
goes where. Document those rules here so the agent doesn't have to
ask every time. Examples:

- `"check my work inbox"` → use the work account (whatever address
  that is for you), filter `is:unread -category:promotions`.
- `"message <colleague-name>"` → which platform? Slack? WhatsApp?
- `"what's the temperature"` → which weather skill? Which units?

When the agent is unsure between two options, **it asks** rather
than guessing. Add explicit rules here only when you're tired of
re-stating the same preference.

## Memory and persistence

The agent's persistent memory lives in three layers:

1. **Auto-memory** (`memories/MEMORY.md`, `memories/USER.md`,
   others): plaintext markdown files the agent reads on every
   session start and updates as it learns. Edit directly to steer.
2. **Hindsight bank** (Postgres, recall via the `recall` tool):
   semantic memory accumulated across sessions. Don't edit
   directly; the agent writes via the `remember` tool, you can
   inspect via `hindsight ls`.
3. **`AGENTS.md` (this file)**: tool selection hints, slowly
   evolving as the agent finds better patterns.

## Self-update

If the agent discovers a better invocation pattern during a session
(e.g. `flag --foo` works better than `flag --bar` for a given
request), it should update the relevant section of this file at
session-end. **Convention:** edit the existing line in place —
don't append "NOTE:" comments. Drop a short rationale in the commit
message if you're versioning this in your fork.

## Things to remove or rewrite

This is a starter. The patterns above are illustrative, not
prescriptive. Treat each section as "delete what you don't use,
add what you do." The agent works best when this file reflects
*your* tool choices, not someone else's.
