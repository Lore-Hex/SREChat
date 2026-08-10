# SREChat: multi-master chat that survives losing a cloud

SREChat is a BEAM/Elixir chat backend that runs as **several equal masters
— one per cloud** — and keeps serving when the network between them breaks.
Every region accepts writes during a partition, and the regions converge when
it heals. It is named for the thing that is famously hard to kill.

It speaks a CometChat-compatible wire protocol, so the CometChat JavaScript,
React Native, and iOS SDKs talk to it directly by overriding their host —
`CometChat.login`, `sendMessage`, `MessagesRequestBuilder`,
`ConversationsRequestBuilder`, listeners, and reactions all work unchanged.
It descends from [SREChat](https://github.com/Lore-Hex/SREChat), which
provides that compatibility layer; SREChat adds the multi-master half.

**License:** AGPL-3.0-or-later (inherited from SREChat).

## How the multi-master part works

* **Coordination-free ids.** Message ids are `41 bits ms | 3 bits region |
  9 bits sequence` — 53 bits exactly, because ids reach JavaScript clients as
  JSON numbers and `2^53-1` is `Number.MAX_SAFE_INTEGER`. No shared counter,
  so no region needs to reach another to accept a write. The layout is proven
  JS-safe at compile time.
* **An oplog per region.** Every mutation appends to that region's Redis
  Stream *inside the same atomic script that commits the records*, so nothing
  can commit unannounced or be announced without committing.
* **Tailers with convergent merges.** Each region tails its peers. Messages
  replay in full; receipt cursors max-merge and never regress; everything else
  is last-writer-wins on `(timestamp, origin, stream id)`, so both sides of a
  partition independently pick the same winner.
* **Gaps refuse to heal silently.** If a region falls behind its peer's stream
  retention, the tailer stops and says so rather than skipping the missing
  middle and diverging forever.

Verified continuously, not just asserted: `tools/chaos/chaos.py` boots three
real regions with three Redis servers, cuts the links, proves both sides keep
serving, heals, and proves byte-identical convergence. It runs in CI on every
push.

See [`docs/runbooks/multi-master.md`](docs/runbooks/multi-master.md) for
configuration, partition semantics, region replacement, and recovery.

## Security

Read [SECURITY.md](SECURITY.md) before deploying. The short version:
`COMETCHAT_API_KEY` is an admin credential and must never ship inside a
client app; `ACCEPT_UID_TOKENS` is for development and demos only; and peer
replication links must ride a private tunnel or `rediss://`.

## API coverage matrix

### Covered APIs

| Area | SDK/API surface | Routes | Coverage |
|---|---|---|---|
| Settings and auth | SDK init settings, `CometChat.login(authToken)`, `getLoggedinUser`, logout token revocation | `GET /settings`, `POST /users/:uid/auth_tokens`, `POST /admin/users/auth`, `DELETE /admin/users/auth/:authToken`, `GET /me`, `PUT /me`, `DELETE /me` | Covered by ExUnit API tests and Playwright SDK contract tests. `PUT /me` returns the user, authToken, jwt/fat placeholders, wsChannel, and SDK settings. |
| Local JWT and sessions | SDK session/JWT compatibility payloads | `POST /me/jwt`, `POST /user_sessions` | Covered by ExUnit API tests. Local JWTs are HMAC-signed SDK compatibility credentials; they remain valid only while the underlying auth token exists, and revoking that token invalidates both. |
| Users | List, search, paginate, create, update, deactivate, reactivate, fetch with block state | `GET /users`, `POST /users`, `PUT /users`, `GET /users/:uid`, `PUT /users/:uid`, `DELETE /users/:uid` | Covered by store and API regression tests. |
| Blocks | Block, unblock, list blocked users, `blockedByMe`, `hasBlockedMe` | `GET /blockedusers`, `POST /blockedusers`, `DELETE /blockedusers` | Covered by ExUnit API tests and Playwright SDK contract tests. |
| Groups and membership | List, search, paginate, create, update, fetch, delete, join public/password groups, member list, add/remove members, update scopes, owner/moderator member management | `GET /groups`, `POST /groups`, `GET /groups/:guid`, `PUT /groups/:guid`, `DELETE /groups/:guid`, `GET /groups/:guid/members`, `POST /groups/:guid/members`, `PUT /groups/:guid/members`, `DELETE /groups/:guid/members`, `PUT /groups/:guid/members/:uid`, `DELETE /groups/:guid/members/:uid` | Covered by store/API/Redis tests and SDK group join contract tests. User-token member writes require group owner/admin/moderator/coOwner privileges. |
| Group bans | Ban, unban, list/search banned users | `GET /groups/:guid/bannedusers`, `POST /groups/:guid/bannedusers/:uid`, `DELETE /groups/:guid/bannedusers/:uid` | Covered by API regression and Redis cleanup tests. |
| Messages | Text, custom, media-shaped messages, multipart media upload, admin sends, validation, deterministic pagination, cursor metadata | `POST /messages`, `GET /users/:uid/messages`, `GET /groups/:guid/messages`, `GET /messages/:messageId`, `GET /user/messages/:muid` | Covered by store tests, API tests, media upload tests, and Playwright SDK contract tests. Message reads, MUID lookup, threads, reactions, and receipts require conversation participation. |
| Threads | Send replies and fetch thread messages | `POST /messages/:parentId/thread`, `GET /messages/:parentId/thread` | Covered by API regression tests. |
| Message actions | Edit/delete action messages, sender/group-moderator authorization, full-access API-key moderation, and hidden deleted-message fetch behavior | `PUT /messages/:messageId`, `DELETE /messages/:messageId` | Covered by store/API tests and SDK delete contract tests. |
| Unread and receipt state | Unread count fetches, mark read, mark unread, delivered cursors, read cursor rewind | `GET /messages?unread=1&count=1`, `POST /users/:uid/conversation/read`, `POST /groups/:guid/conversation/read`, `DELETE /users/:uid/conversation/read`, `DELETE /groups/:guid/conversation/read`, `POST /users/:uid/conversation/delivered`, `POST /groups/:guid/conversation/delivered` | Covered by store/API/Redis tests and WebSocket receipt tests. SDK v4 can also send read/delivered receipts over WebSocket, which update receipt state. |
| Conversations | List conversations, fetch user/group conversation, hide a conversation for the current user, delete a conversation by canonical conversation id | `GET /conversations`, `GET /users/:uid/conversation`, `GET /groups/:guid/conversation`, `DELETE /users/:uid/conversation`, `DELETE /groups/:guid/conversation`, `DELETE /conversations/:conversationId` | Covered by store/API/Redis tests and SDK conversation contract tests. |
| Reactions | Native reaction add/remove/list/filter and `callExtension("reactions", ...)` fallback | `POST /messages/:messageId/reactions/:reaction`, `DELETE /messages/:messageId/reactions/:reaction`, `GET /messages/:messageId/reactions`, `GET /messages/:messageId/reactions/:reaction`, `MATCH /extensions/:name/*path`, `MATCH /v1/*path` | Covered by store/API tests. The real SDK extension contract is optional and requires wildcard HTTPS DNS. |
| Media serving | Serve allowlisted uploaded media through private S3 signed URLs and a `/media/:file` S3 proxy fallback | `GET /media/:file` | Covered by API and store regression tests. Production does not use durable local media storage. |
| WebSocket | SDK auth event, message/action/reaction broadcasts, read receipts, ping/malformed frame handling | `/`, `/ws`, `/socket` | Covered by WebSocket handler tests. |
| Health checks | Plain HTTP process health | `GET /health` | Covered by API regression tests. |

### Partial, stubbed, or not-done APIs

| Area | Routes/API | Current behavior | Status |
|---|---|---|---|
| Generic message list | `GET /messages` without `unread=1&count=1` | Returns an empty list. Use `GET /users/:uid/messages`, `GET /groups/:guid/messages`, or thread routes for real message history. | Partial |
| Extensions beyond reactions | `MATCH /extensions/:name/*path`, extension-host fallback | All extension calls are interpreted as reaction add/remove requests. Non-reaction extensions are not implemented. | Partial |
| SDK sessions | `POST /user_sessions` | Returns a local compatibility payload only. There is no external CometChat session registry. | Partial |
| Broader CometChat product areas | Calls, typing indicators, live presence/occupancy, push notifications, moderation workflows, webhooks, roles, polls, message translations | No route-level implementation unless listed in the covered matrix above. | Not done |

## WebSocket

The SDK builds the WebSocket URL from the `/me` settings as:

```text
wss://<CHAT_HOST>:<CHAT_WSS_PORT>
```

SREChat accepts WebSocket connections at `/`, `/ws`, and `/socket`. It handles the SDK auth event, broadcasts messages/actions/reactions, and processes read receipts.

## Important compatibility note

This implementation targets the inspected JavaScript SDK wire shape for `@cometchat/chat-sdk-javascript@4.1.8` and the React Native SDK host-override surface used by `@cometchat/chat-sdk-react-native@4.0.10`. CometChat does not publish a stable public REST contract for every SDK-internal endpoint. Pin SDK versions in production and run the contract harness before upgrading.

## Local development

```bash
mix deps.get
mix test
mix test.load
PORT=4000 PUBLIC_HOST=localhost PUBLIC_WS_PORT=8443 mix run --no-halt
```

The JavaScript SDK always uses HTTPS for overridden hosts, so the contract harness expects a TLS reverse proxy. The supplied Docker Compose includes Caddy in front of the Elixir service.
Compose publishes Caddy on both `https://localhost` and `https://localhost:8443`; the SDK uses `localhost:8443` for the initial override and the advertised production-style `localhost:443` settings for follow-on REST/WebSocket calls.

```bash
docker compose up --build
cd contract
npm install
SRECHAT_TARGET_HOST=localhost:8443/v3.0 npm test
```

For local Playwright, Caddy uses an internal/self-signed certificate and the Playwright config ignores HTTPS errors.

## App-side URL swizzle

If you can adjust only the CometChat app settings creation, point both SDK hosts at the replacement:

```js
const appSettings = new CometChat.AppSettingsBuilder()
  .setRegion("us")
  .overrideClientHost("chat.example.com/v3.0")
  .overrideAdminHost("chat.example.com/v3")
  .autoEstablishSocketConnection(true)
  .build();

await CometChat.init(APP_ID, appSettings);
```

All existing CometChat method calls remain the same.

For a literal zero-code swizzle, deploy TLS and DNS so the SDK's existing CometChat hostnames resolve to this service. That is usually harder operationally than using `overrideClientHost`/`overrideAdminHost`.

The React Native SDK exposes the same host override methods:

```ts
const appSettings = new CometChat.AppSettingsBuilder()
  .subscribePresenceForAllUsers()
  .setRegion("us")
  .overrideClientHost("chat.example.com/v3.0")
  .overrideAdminHost("chat.example.com/v3")
  .autoEstablishSocketConnection(true)
  .build();
```

## Runtime configuration

Runtime environment variables are read from `config/runtime.exs`, so container and release deployments can change them without rebuilding the image.

| Variable | Default | Purpose |
|---|---:|---|
| `PORT` | `4000` | HTTP port the Elixir app listens on |
| `PUBLIC_HOST` | `localhost` | Host returned to SDK in `/me.settings.CHAT_HOST` |
| `PUBLIC_WS_PORT` | `PORT` | Port returned as `/me.settings.CHAT_WSS_PORT` |
| `COMETCHAT_APP_ID` | `local-app` | App ID accepted/reported by the clone |
| `COMETCHAT_API_KEY` | `local-api-key` outside prod, blank in prod | Admin API key for server-side routes. Blank disables admin API-key access rather than opening routes. |
| `LOCAL_JWT_SECRET` | `COMETCHAT_API_KEY` fallback, runtime random if neither is set in prod | HMAC secret for local JWT compatibility tokens. Set this explicitly for stable multi-node deployments. |
| `COMETCHAT_REGION` | `us` | Region returned to SDK settings |
| `CORS_ALLOWED_ORIGINS` | `*` outside prod, empty in prod | Comma-separated browser origins allowed to call the API. Set this to your real app origins in production. |
| `EXTENSION_DOMAIN` | `PUBLIC_HOST` | Extension domain used by `callExtension` URL generation |
| `REDIS_URL` | unset | Optional Redis URL for durable per-record storage |
| `REDIS_KEY_PREFIX` | `sre_chat` | Redis namespace prefix for record keys, indexes, and counters |
| `REDIS_SNAPSHOT_KEY` | `sre_chat:snapshot:v1` | Legacy import key for older single-snapshot deployments |
| `REDIS_PUBLISHER_LANES` | `4` | Ordered Redis Pub/Sub publisher lanes. Conversations are deterministically sharded so one slow publish cannot delay unrelated rooms or DMs. Clamped to 1-16. |
| `SEED_USERS_JSON` | built-in Alice/Bob/Carol without auth tokens | Initial users. List or map. Users may include `authToken`. |
| `SEED_GROUPS_JSON` | built-in public `lobby` | Initial groups. List or map. |
| `ACCEPT_UID_TOKENS` | `false` outside tests | Accept `uid:<uid>` developer tokens. Enable only for local contract tests. |
| `MEDIA_STORAGE` | `s3` in prod, `local` otherwise | Upload backend. Production requires S3 and rejects local durable media storage. |
| `S3_BUCKET` | unset | Private S3 bucket used when `MEDIA_STORAGE=s3`. |
| `S3_REGION` | `AWS_REGION` | S3 bucket region. |
| `S3_PRESIGNED_URL_TTL_SECONDS` | `3600` | Expiration for presigned S3 media URLs returned to clients. S3 caps this at seven days, and ECS role credentials may expire sooner. |
| `UPLOAD_DIR` | `priv/static/uploads` outside prod, unset in prod | Local development upload directory. Ignored in production because local media storage is disabled. |
| `REQUEST_BODY_LIMIT` | `10000000` | Max parsed request body size in bytes |
| `UPLOAD_MAX_BYTES` | `10000000` | Max single uploaded media file size in bytes |
| `UPLOAD_ALLOWED_MIME_TYPES` | image/audio/video/pdf/text allowlist | Comma-separated allowlist for stored uploads |
| `DM_HISTORY_CONNECT_GRACE_MS` | `600` outside tests, `0` in tests | Compatibility delay on direct-message history responses so the CometChat JS SDK WebSocket state is connected before immediate `markAsRead()` calls. Set `0` to disable. |
| `PUBLIC_MEDIA_BASE_URL` | unset | Absolute stable media URL base; otherwise `/media/<file>`. With private S3, keep this pointed at SREChat for stored fallback URLs while outbound payloads are rewritten to presigned S3 URLs. |

## Observability

`GET /observability` requires the configured admin API key in the `apiKey`/`apikey`
header. It returns per-process counters, gauges, and latency histograms without message
contents or auth tokens. Cross-instance delivery exposes these metrics:

- `redis.publish.queue_ms`: time an event waited before its publisher lane ran;
- `redis.publish.duration_ms`: Redis `PUBLISH` command time;
- `redis.publish.queue_length`: queued events remaining on each lane;
- `redis.pubsub.delivery_ms`: publish enqueue to receipt on a peer SREChat instance;
- `redis.pubsub.received`: peer events received, tagged by event type.

SREChat logs a warning when an individual Redis publish takes at least 250 ms. These
signals separate HTTP/store latency from cross-instance fanout latency during an incident.

## Admin moderation

Server-side moderation uses the CometChat-style admin API key. Send the configured
`COMETCHAT_API_KEY` in the `apikey` or `apiKey` header. Admin requests do not need an
`authToken`, and message mutations run with full moderation access:

```bash
curl -X PUT "$SRECHAT_URL/v3/messages/$MESSAGE_ID" \
  -H "apikey: $COMETCHAT_API_KEY" \
  -H "content-type: application/json" \
  -d '{"data":{"text":"moderated text"}}'

curl -X DELETE "$SRECHAT_URL/v3/messages/$MESSAGE_ID" \
  -H "apikey: $COMETCHAT_API_KEY"
```

User-token requests keep SDK-style permissions: direct messages can be edited or
deleted only by their sender; group messages can be edited or deleted by their sender
or by a group `owner`, `admin`, `moderator`, or `coOwner`. User-token member
management has the same group moderator boundary, so participants cannot add
members or escalate scopes.

## Persistence strategy

By default all state is in one OTP GenServer. If `REDIS_URL` is set, each mutation is also persisted into Redis as per-record keys under `REDIS_KEY_PREFIX`:

- `sre_chat:users:<uid>`
- `sre_chat:tokens:<authToken>`
- `sre_chat:groups:<guid>`
- `sre_chat:members:<guid>`
- `sre_chat:messages:<messageId>`
- `sre_chat:conversation_messages:<conversationId>`
- `sre_chat:thread_messages:<parentMessageId>`
- `sre_chat:reads:<uid>`
- `sre_chat:delivered:<uid>`
- `sre_chat:hidden_conversations:<uid>`
- `sre_chat:reactions:<messageId>`
- `sre_chat:blocks:<uid>`
- `sre_chat:banned:<guid>`
- `sre_chat:message_muids:<muid>` for client message-id lookup
- `sre_chat:user_conversations:<uid>` for conversation list and unread fanout
- `sre_chat:conversation_users:<conversationId>` for participant-scoped cleanup
- `sre_chat:user_groups:<uid>` for group conversation discovery
- `sre_chat:counter:<counterName>`
- `sre_chat:index:<bucket>` sets for reloadable key discovery

On startup, SREChat reloads state from those Redis keys. Normal mutations write only the touched records, indexes, and counters; reset and legacy imports replace the namespace. If no per-key namespace has been initialized but `REDIS_SNAPSHOT_KEY` exists, SREChat imports that legacy JSON snapshot into the per-key layout.

When Redis is enabled, Store behaves as a local read-through/write-through cache over the per-key Redis layout:

- mutating calls take scoped Redis locks, usually by conversation, message, group, user, or token instead of a single global lock;
- writes persist only touched records and index entries;
- message, membership-action, and reaction IDs are allocated through Redis-backed monotonic counters so separate nodes do not race stale local counters;
- targeted read-through refresh pulls only records a request can touch, such as a conversation message list plus its messages, a token plus its user, or a group plus its members;
- broad query paths use Redis index sets or secondary indexes rather than whole-state request refreshes: user/group lists read only their bucket indexes, unread and conversation lists read `user_conversations`/`user_groups`, MUID lookup reads `message_muids`, and destructive cleanup reads `conversation_users`;
- reset and legacy imports remain namespace-wide operations.

This keeps Redis as a high-scale write-through/read-through record store for the current API surface, while each BEAM node keeps a local Store cache. Horizontal task scaling is supported by Redis-scoped locks/counters, targeted read-through refreshes, and Redis Pub/Sub-triggered cache refresh on peer nodes before websocket fanout. Message writes are serialized by conversation or room, reaction writes by message, and membership writes by group. For a larger production deployment, the next architecture step is PostgreSQL as the source of truth for users, groups, messages, receipts, moderation logs, and searchable audit history, with Redis kept for Pub/Sub, hot counters, ephemeral presence, rate limits, and short-lived caches.

WebSocket events are also fanned out through Redis Pub/Sub so instances behind a load balancer can notify each other's connected clients. Publishers are conversation-sharded across ordered lanes: messages, edits, deletes, receipts, and reactions in one room or DM preserve order, while a delayed Redis command for one conversation does not block unrelated conversations on the same SREChat instance.

## AWS deployment sketch

Use one of these patterns:

1. **ECS/Fargate + ALB + ElastiCache Redis**
   - ALB terminates TLS for `chat.example.com` and, if using `callExtension`, `*.chat.example.com`.
   - ALB forwards HTTP and WebSocket upgrades to the service on `PORT=4000`.
   - ElastiCache Redis set as `REDIS_URL` for durable per-record storage.

2. **EC2/ASG + Caddy/Nginx + Redis**
   - Caddy/Nginx terminates TLS and proxies `/v3.0/*`, `/media/*`, and `/` WebSocket traffic to the BEAM app.

Recommended env for ALB/Fargate:

```text
PORT=4000
PUBLIC_HOST=chat.example.com
PUBLIC_WS_PORT=443
COMETCHAT_APP_ID=<your app id>
COMETCHAT_REGION=us
EXTENSION_DOMAIN=chat.example.com
REDIS_URL=redis://<elasticache-endpoint>:6379/0
```

## Test matrix

### ExUnit unit/API tests

- Auth token login and `getLoggedinUser` payload compatibility
- Admin token generation
- User and group message send/fetch
- Group join and group message membership checks
- Text/custom/media-shaped messages
- Message edit/delete action payloads
- Conversations, unread counts, and delivered cursors
- Read/unread/delivered transitions
- Native reactions
- Owner/moderator-only member and message moderation
- Redis per-key persistence, secondary indexes, targeted refresh, scoped write preservation, and monotonic Redis counters

### Load and performance tests

Load tests are excluded from the default `mix test` suite. They include sequential baselines and concurrent Store, Plug HTTP, Redis write-through, and receipt fanout pressure. Run them explicitly:

```bash
mix test.load
```

Useful knobs:

| Variable | Default | Purpose |
|---|---:|---|
| `SRECHAT_LOAD_USERS` | `100` | Distinct users for direct-message load |
| `SRECHAT_LOAD_MESSAGES` | `2000` | Direct Store messages |
| `SRECHAT_LOAD_GROUP_MEMBERS` | `150` | Members in the group fanout test |
| `SRECHAT_LOAD_GROUP_MESSAGES` | `600` | Group messages |
| `SRECHAT_LOAD_HTTP_MESSAGES` | `500` | Plug HTTP message sends |
| `SRECHAT_LOAD_REDIS_MESSAGES` | `300` | Redis-backed message sends |
| `SRECHAT_LOAD_REDIS_INDEX_MESSAGES` | `240` | Redis secondary-index write/read checks |
| `SRECHAT_LOAD_CONCURRENCY` | `16` | Concurrent Store writer tasks |
| `SRECHAT_LOAD_WORKER_MESSAGES` | `150` | Messages per concurrent Store writer |
| `SRECHAT_LOAD_HTTP_CONCURRENCY` | `12` | Concurrent Plug HTTP writer tasks |
| `SRECHAT_LOAD_HTTP_WORKER_MESSAGES` | `50` | Messages per concurrent HTTP writer |
| `SRECHAT_LOAD_REDIS_CONCURRENCY` | `8` | Concurrent Redis-backed writer tasks |
| `SRECHAT_LOAD_REDIS_WORKER_MESSAGES` | `60` | Messages per concurrent Redis writer |
| `SRECHAT_LOAD_RECEIPT_CONCURRENCY` | `16` | Concurrent receipt writer tasks |
| `SRECHAT_MIN_STORE_MSG_PER_SEC` | `300` | Minimum direct Store throughput |
| `SRECHAT_MIN_GROUP_MSG_PER_SEC` | `100` | Minimum group-message throughput |
| `SRECHAT_MIN_HTTP_MSG_PER_SEC` | `100` | Minimum Plug HTTP throughput |
| `SRECHAT_MIN_REDIS_MSG_PER_SEC` | `20` | Minimum Redis-backed throughput |
| `SRECHAT_MIN_CONCURRENT_STORE_MSG_PER_SEC` | `200` | Minimum concurrent Store throughput |
| `SRECHAT_MIN_CONCURRENT_HTTP_MSG_PER_SEC` | `100` | Minimum concurrent Plug HTTP throughput |
| `SRECHAT_MIN_CONCURRENT_REDIS_MSG_PER_SEC` | `20` | Minimum concurrent Redis throughput |
| `SRECHAT_MIN_RECEIPT_PER_SEC` | `100` | Minimum concurrent receipt throughput |
| `REDIS_TEST_URL` | `redis://localhost:6379/15` | Redis URL for Redis load/persistence tests |

### Playwright contract tests against the real SDK

- `CometChat.init` with overridden hosts
- `CometChat.login(authToken)` and `CometChat.getLoggedinUser()`
- `CometChat.TextMessage` + `sendMessage`
- `MessagesRequestBuilder().setUID().fetchPrevious()`
- `ConversationsRequestBuilder().fetchNext()`
- `getUnreadMessageCountForAllUsers()`
- `markAsRead(message)`
- `deleteMessage(messageId)`
- `CustomMessage`, `MediaMessage`, `joinGroup`, and native reactions
- Optional `callExtension` reaction contract when wildcard extension DNS is configured
