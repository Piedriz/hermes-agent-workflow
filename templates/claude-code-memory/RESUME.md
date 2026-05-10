---
name: RESUME — live conversation state
description: Read FIRST on any session resume. Snapshot of the in-flight conversation, refreshed after each meaningful turn. If timestamp is stale, also tail the .jsonl pointer for verbatim context.
type: project
---
**Last updated**: (no session yet on this host)

This is a stub. The first claude session on this host should refresh
this file per the protocol in `feedback_resume_protocol.md`. The
expected sections are:

- Active thread (one paragraph)
- Last user message (verbatim)
- Last assistant action (one-line summary)
- In flight (this turn)
- Recently completed (terse list, newest first)
- Open questions awaiting the user
- Latest .jsonl pointer + recovery recipe
