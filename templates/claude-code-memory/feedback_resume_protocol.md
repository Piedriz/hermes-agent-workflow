---
name: Resume protocol — keep RESUME.md current
description: After each meaningful user exchange, refresh `memory/RESUME.md` so a fresh session resume (after crash, claude-remote rebind, /compact, host flip) picks up where we left off without re-pasting context.
type: feedback
---
After each meaningful user exchange, refresh
`<your-claude-projects-dir>/memory/RESUME.md` (which is symlinked into
`hosts/<your-host>/claude-code-memory/RESUME.md`) before sending the
response. That file is the live snapshot a fresh session resume reads
first; if it's stale, the resume cold-starts with stale context and
the user has to re-paste from another browser tab — which is exactly
what this protocol is for.

**Why:** Multi-host claude-remote setups are fragile in known ways:
tailnet/MagicDNS toggles break addressability, `/compact` can drop
mid-conversation context, and the `.jsonl` transcripts are local-only
(8 MB+ per session, not git-synced — see
`scripts/prune-claude-cc-history.sh`). Memory + the curated narrative
(`claude-session-history.md`) are what survive crashes. RESUME.md is
the always-up-to-date entry point so the "what were we just doing"
question is answered without spelunking the .jsonl.

**How to apply:**
- Refresh RESUME.md after any user message that adds material
  context, decision, or in-flight task — not after pure clarification
  questions.
- Batch is fine: if 3 quick exchanges happen in 2 min, one RESUME
  write at the end captures all three. Don't burn turns on
  bookkeeping.
- Update the timestamp in the frontmatter / "Last updated" line each
  time. A fresh resume uses that to decide whether to also tail the
  `.jsonl` (recipe is in RESUME.md itself).
- Keep entries terse — verbatim user msg, one-line summary of your
  response, in-flight list, open questions. No diff dumps.
- The latest .jsonl pointer at the bottom of RESUME.md needs to track
  the actual current session id. On a brand-new session resume, the
  .jsonl path will have changed — update it once you've confirmed it.
- When switching projects/threads (e.g., end of debug session, start
  of new feature), prune the "Recently completed" list to the last
  ~5 items so it stays scannable.

**What it complements (and doesn't replace):**
- `claude-session-history.md` (narrative, durable, append-only) is
  still the long-form record. RESUME.md is the live cursor on top of
  it.
- LEADING EDGE pointer in MEMORY.md is for *operational* state
  ("which host is active, what's the latest install gotcha"). That
  changes infrequently. RESUME changes constantly.
- Memory `.md` files capture durable facts/preferences. RESUME
  captures volatile session context.
