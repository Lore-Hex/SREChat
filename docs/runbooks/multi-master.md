# Runbook — Multi-master regions

The single source of truth for running RoachChat as one logical chat
service across independent regions (one per cloud), each fully usable
during a network partition, converging on heal.

## The design in one paragraph

Every region is a complete deployment: BEAM node(s) + its own Redis.
Writes commit locally and append to the region's **oplog** (a Redis
Stream) inside the same atomic script — nothing can commit without being
announced, or be announced without committing. Every region **tails**
every peer's oplog and applies the ops through its own store with
convergent merge rules: messages replay in full (ids are region-prefixed
and collision-free by construction), receipt cursors max-merge and never
regress, everything else is last-writer-wins on `(ts, origin, stream_id)`
— both sides of a partition deterministically pick the same winner.
Derived state (conversation lists, unread counts, indexes) never
travels; each region recomputes it from the records it applies.

## Configuration

Every region sets, in addition to its normal env:

| env | value |
|---|---|
| `ID_ALLOCATOR` | `region` (required — the global counter cannot be multi-master) |
| `REGION_INDEX` | unique per region, `0..7` |
| `REPLICATION_MODE` | `multi_master` |
| `PEER_REGIONS` | `1=rediss://…,2=rediss://…` — each peer's **Redis**, not its API |
| `REDIS_KEY_PREFIX` | identical across regions (default `open_chat`) |

Misconfiguration (multi_master without region ids, own index in
`PEER_REGIONS`, duplicate indexes) refuses to boot, loudly.

`PEER_REGIONS` URLs are the partition boundary: the peer's Redis being
unreachable IS the partition, and the region keeps serving from local
state while the tailer retries forever. Cross-cloud links must be
`rediss://` with auth, or ride a private tunnel — never a plain-text
public listener.

## What survives a partition

* Both sides keep accepting sends, reads, joins, receipts — full service
  from local state. Message ids cannot collide (region bits).
* On heal, tailers drain the backlog in order; every region converges to
  the same message set, membership, and cursors.
* Verified continuously by `tools/chaos/chaos.py` (also a CI job): three
  real regions, three redis-servers, links cut by killing TCP proxies,
  both-sides-live asserted during the partition, byte-identical
  convergence asserted after heal.

Accepted v1 anomalies (documented in `OpenChat.Replication.Ingest`):
concurrent membership edits to the SAME group on both sides of a
partition resolve whole-map last-writer-wins; reactions likewise.
Messages are never lost. Receipt EVENTS don't re-broadcast cross-region
(the cursors replicate; ticks catch up on the next fetch).

## Operating notes

**Add a region:** deploy with a fresh `REGION_INDEX`, empty Redis, and
`PEER_REGIONS` covering the existing regions; add the new region to the
existing regions' `PEER_REGIONS` and restart them. A fresh region's
tailers start at cursor `0-0` and replay peers' full retained history.

**Replication lag:** `replication.events` metrics per peer (`applied`,
`peer_unreachable`, `apply_failed`, `gap_detected`). A tailer holds a
lease per peer in local Redis, so multi-node regions elect exactly one
tailing node per peer.

**Gap (`gap_detected`, tailer degraded):** the region was partitioned
longer than the peer's stream retention (MAXLEN ~1M entries). The tailer
REFUSES to continue — skipping the trimmed middle would diverge silently
and forever. Recovery: stop the degraded region, copy a healthy peer's
record keys (`<prefix>:<bucket>:*`) into its Redis (or replay a
snapshot), delete `<prefix>:repl_cursor:<peer>`, start; the tailer
resumes from the stream's current tail via fresh replay of what it
copied. Then re-verify with the chaos harness against staging before
trusting it.

**Rollback to single-master:** set `REPLICATION_MODE=off` everywhere and
point all traffic at one region. Do NOT flip `ID_ALLOCATOR` back to
`global` unless `next_id` is first raised above the largest allocated
region id (see `OpenChat.RegionId`).

## Local three-region sandbox

```bash
python3 tools/chaos/chaos.py
```

boots the whole topology (3 redis, 3 regions, 6 proxy links) on
localhost, runs the partition scenario, and tears everything down.
Region logs land in `$TMPDIR/roach-chaos/`.
