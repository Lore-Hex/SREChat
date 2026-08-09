# Security

## Reporting a vulnerability

Please report privately via GitHub's [Report a
vulnerability](https://github.com/Lore-Hex/RoachChat/security/advisories/new)
form rather than a public issue. We aim to acknowledge within 72 hours.

## What this software is

RoachChat is a multi-master, partition-tolerant chat backend speaking a
CometChat-compatible wire protocol. It is designed to keep serving during
a cloud or network partition, which means it deliberately accepts writes
on both sides of a split and converges afterwards.

## Deploying it safely

The defaults are safe; the ways to make it unsafe are worth naming.

**`COMETCHAT_API_KEY` is an admin credential.** It authorizes the
server-to-server admin routes (create users, mint auth tokens, moderate
messages). Keep it on servers only. **Never embed it in a mobile or web
client** — anything shipped to a device is extractable. Clients should
authenticate to your own service and receive a user auth token. In
production the app must obtain that token from your sign-in flow, not
hold an admin key. Blank disables the admin routes entirely; anything
under 32 characters is rejected at boot in prod.

**`ACCEPT_UID_TOKENS=true` accepts `uid:<name>` as an auth token.** It
exists for local development, tests, and demo/review builds — it means
anyone can log in as anyone. Do not enable it for a production
deployment with real users.

**Peer replication links carry all your data.** `PEER_REGIONS` points at
each peer region's Redis. Redis has no transport security of its own, so
these links must ride a private tunnel (this deployment uses WireGuard)
or use `rediss://` with authentication. Never expose a region's Redis on
a public interface.

**Media storage.** `MEDIA_STORAGE=local` is refused in prod unless you
explicitly set `ALLOW_LOCAL_MEDIA_STORAGE=true`, which is appropriate
only for a single-box region with durable storage. `s3` is the default.

**Transport.** Terminate TLS in front of the app (the supplied Caddy
config gets real certificates automatically). The websocket idle timeout
is derived from `WEBSOCKET_HEARTBEAT_MS`; disabling the heartbeat moves
liveness responsibility to your proxy layer.

## Supply chain

CI runs `tools/audit.sh` on every push and pull request. It fails the
build on any dependency advisory that is not explicitly allowlisted in
`.hex-audit-allow` with a written rationale, and *also* fails on stale
allowlist entries, so an accepted advisory cannot outlive its fix.

Secret scanning and push protection are enabled on this repository.
