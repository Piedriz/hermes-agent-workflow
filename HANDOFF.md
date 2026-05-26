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
secure context. `scripts/bootstrap.sh` generates a host-local self-signed
certificate and writes `SIDEKICK_HTTPS_CERT_FILE` /
`SIDEKICK_HTTPS_KEY_FILE` into the Sidekick checkout's `.env`.

Self-signed certs usually require the browser to accept or trust the cert
once. For a trusted cert without a browser warning, put Tailscale Serve,
Caddy, nginx, or another TLS proxy in front of Sidekick.
