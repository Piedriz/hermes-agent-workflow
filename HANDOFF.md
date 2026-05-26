# Host Handoff

This workflow assumes one active writer at a time. The active host runs
Hermes services, Sidekick, and sync crons; standby hosts can be installed
but should not mutate encrypted state dumps.

`ACTIVE_HOST` is the coordination sentinel. The sync scripts check it and
exit quietly on standby hosts.

## Normal Switch

On the current active host:

```bash
cd ~/code/hermes-agent-workflow
scripts/handoff-out.sh
```

That stops user-facing services, captures final dumps for:

- `~/.hermes/state.db` to `hermes-data/state.sql`
- `~/.hermes/sidekick.db` to `sidekick-data/sidekick.sql`
- Hindsight Postgres to `hindsight-data/**`

It then clears `ACTIVE_HOST`, commits, and pushes.

On the new host:

```bash
cd ~/code/hermes-agent-workflow
git pull --ff-only
scripts/handoff-in.sh
```

That restores Hermes state, Sidekick UI state, and Hindsight memory;
relinks runtime directories; installs expected crons; starts services; and
runs `scripts/handoff-smoke-test.sh`.

## Forced Takeover

If the old active host is dead or unreachable:

```bash
scripts/handoff-in.sh --force
```

This restores the latest committed dumps. Any writes made on the dead host
after its last successful sync are lost.

## HTTPS

Sidekick should be served over HTTPS for any browser that is not on
`localhost`; microphone, PWA, push, and WebRTC features require a browser
secure context. `scripts/bootstrap.sh` prefers Tailscale Serve and maps:

```text
https://<host>.<tailnet>.ts.net/ -> http://127.0.0.1:3001
```

That gives a trusted certificate with no browser warning. If Tailscale
Serve cannot be configured, run this once and re-run bootstrap:

```bash
sudo tailscale set --operator=$USER
```

The fallback is native Sidekick HTTPS with a self-signed cert on
`https://<host>:3001`; that encrypts traffic but browsers will label it
"Not Secure" until the cert is trusted locally.
