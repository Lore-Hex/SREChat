# OpenChat: AGPL CometChat-compatible drop-in endpoint

OpenChat is a BEAM/Elixir replacement for the covered subset of CometChat. It is designed for a URL-swizzled CometChat JavaScript SDK to call directly, without changing call sites such as `CometChat.login`, `CometChat.sendMessage`, `MessagesRequestBuilder`, `ConversationsRequestBuilder`, message listeners, and reaction calls.

**License:** AGPL-3.0-or-later.

## API coverage matrix

### Covered APIs

| Area | SDK/API surface | Routes | Coverage |
|---|---|---|---|
| Settings and auth | SDK init settings, `CometChat.login(authToken)`, `getLoggedinUser`, logout token revocation | `GET /settings`, `POST /users/:uid/auth_tokens`, `POST /admin/users/auth`, `DELETE /admin/users/auth/:authToken`, `GET /me`, `PUT /me`, `DELETE /me` | Covered by ExUnit API tests and Playwright SDK contract tests. `PUT /me` returns the user, authToken, jwt/fat placeholders, wsChannel, and SDK settings. |
| Local JWT and sessions | SDK session/JWT compatibility payloads | `POST /me/jwt`, `POST /user_sessions` | Covered by ExUnit API tests. Local JWTs are HMAC-signed compatibility tokens with a 24-hour expiry. |
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
| Media serving | Serve allowlisted uploaded media files with size limits and sanitized storage names | `GET /media/:file` | Covered by API and store regression tests. |
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

OpenChat accepts WebSocket connections at `/`, `/ws`, and `/socket`. It handles the SDK auth event, broadcasts messages/actions/reactions, and processes read receipts.

## Important compatibility note

This implementation targets the inspected JavaScript SDK wire shape for `@cometchat/chat-sdk-javascript@4.1.8`. CometChat does not publish a stable public REST contract for every SDK-internal endpoint. Pin the SDK version in production and run the contract harness before upgrading.

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
OPENCHAT_TARGET_HOST=localhost:8443/v3.0 npm test
```

For local Playwright, Caddy uses an internal/self-signed certificate and the Playwright config ignores HTTPS errors.

## App-side URL swizzle

If you can adjust only the CometChat app settings creation, point both SDK hosts at the replacement:

```js
const appSettings = new CometChat.AppSettingsBuilder()
  .setRegion("us")
  .overrideClientHost("chat.example.com/v3.0")
  .overrideAdminHost("chat.example.com/v3.0")
  .autoEstablishSocketConnection(true)
  .build();

await CometChat.init(APP_ID, appSettings);
```

All existing CometChat method calls remain the same.

For a literal zero-code swizzle, deploy TLS and DNS so the SDK's existing CometChat hostnames resolve to this service. That is usually harder operationally than using `overrideClientHost`/`overrideAdminHost`.

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
| `REDIS_KEY_PREFIX` | `open_chat` | Redis namespace prefix for record keys, indexes, and counters |
| `REDIS_SNAPSHOT_KEY` | `open_chat:snapshot:v1` | Legacy import key for older single-snapshot deployments |
| `SEED_USERS_JSON` | built-in Alice/Bob/Carol without auth tokens | Initial users. List or map. Users may include `authToken`. |
| `SEED_GROUPS_JSON` | built-in public `lobby` | Initial groups. List or map. |
| `ACCEPT_UID_TOKENS` | `false` outside tests | Accept `uid:<uid>` developer tokens. Enable only for local contract tests. |
| `MEDIA_STORAGE` | `local` | Upload backend. Use `s3` for AWS/private S3 storage. |
| `S3_BUCKET` | unset | Private S3 bucket used when `MEDIA_STORAGE=s3`. |
| `S3_REGION` | `AWS_REGION` | S3 bucket region. |
| `UPLOAD_DIR` | `priv/static/uploads` | Uploaded media storage directory |
| `REQUEST_BODY_LIMIT` | `10000000` | Max parsed request body size in bytes |
| `UPLOAD_MAX_BYTES` | `10000000` | Max single uploaded media file size in bytes |
| `UPLOAD_ALLOWED_MIME_TYPES` | image/audio/video/pdf/text allowlist | Comma-separated allowlist for stored uploads |
| `PUBLIC_MEDIA_BASE_URL` | unset | Absolute media URL base; otherwise `/media/<file>`. With private S3, keep this pointed at OpenChat so `/media/<file>` proxies through the service. |

## Admin moderation

Server-side moderation uses the CometChat-style admin API key. Send the configured
`COMETCHAT_API_KEY` in the `apikey` or `apiKey` header. Admin requests do not need an
`authToken`, and message mutations run with full moderation access:

```bash
curl -X PUT "$OPENCHAT_URL/v3/messages/$MESSAGE_ID" \
  -H "apikey: $COMETCHAT_API_KEY" \
  -H "content-type: application/json" \
  -d '{"data":{"text":"moderated text"}}'

curl -X DELETE "$OPENCHAT_URL/v3/messages/$MESSAGE_ID" \
  -H "apikey: $COMETCHAT_API_KEY"
```

User-token requests keep SDK-style permissions: direct messages can be edited or
deleted only by their sender; group messages can be edited or deleted by their sender
or by a group `owner`, `admin`, `moderator`, or `coOwner`. User-token member
management has the same group moderator boundary, so participants cannot add
members or escalate scopes.

## Persistence strategy

By default all state is in one OTP GenServer. If `REDIS_URL` is set, each mutation is also persisted into Redis as per-record keys under `REDIS_KEY_PREFIX`:

- `open_chat:users:<uid>`
- `open_chat:tokens:<authToken>`
- `open_chat:groups:<guid>`
- `open_chat:members:<guid>`
- `open_chat:messages:<messageId>`
- `open_chat:conversation_messages:<conversationId>`
- `open_chat:thread_messages:<parentMessageId>`
- `open_chat:reads:<uid>`
- `open_chat:delivered:<uid>`
- `open_chat:hidden_conversations:<uid>`
- `open_chat:reactions:<messageId>`
- `open_chat:blocks:<uid>`
- `open_chat:banned:<guid>`
- `open_chat:message_muids:<muid>` for client message-id lookup
- `open_chat:user_conversations:<uid>` for conversation list and unread fanout
- `open_chat:conversation_users:<conversationId>` for participant-scoped cleanup
- `open_chat:user_groups:<uid>` for group conversation discovery
- `open_chat:counter:<counterName>`
- `open_chat:index:<bucket>` sets for reloadable key discovery

On startup, OpenChat reloads state from those Redis keys. Normal mutations write only the touched records, indexes, and counters; reset and legacy imports replace the namespace. If no per-key namespace has been initialized but `REDIS_SNAPSHOT_KEY` exists, OpenChat imports that legacy JSON snapshot into the per-key layout.

When Redis is enabled, Store behaves as a local read-through/write-through cache over the per-key Redis layout:

- mutating calls take scoped Redis locks, usually by conversation, message, group, user, or token instead of a single global lock;
- writes persist only touched records and index entries;
- message, membership-action, and reaction IDs are allocated through Redis-backed monotonic counters so separate nodes do not race stale local counters;
- targeted read-through refresh pulls only records a request can touch, such as a conversation message list plus its messages, a token plus its user, or a group plus its members;
- broad query paths use Redis index sets or secondary indexes rather than whole-state request refreshes: user/group lists read only their bucket indexes, unread and conversation lists read `user_conversations`/`user_groups`, MUID lookup reads `message_muids`, and destructive cleanup reads `conversation_users`;
- reset and legacy imports remain namespace-wide operations.

This keeps Redis as a high-scale write-through/read-through record store for the current API surface, but the OTP Store process is still a per-instance serialization point. It scales horizontally for independent app instances only as far as Redis locks, counters, and per-request refreshes allow. For a larger production deployment, the next architecture step is PostgreSQL as the source of truth for users, groups, messages, receipts, moderation logs, and searchable audit history, with Redis kept for Pub/Sub, hot counters, ephemeral presence, rate limits, and short-lived caches.

WebSocket events are also fanned out through Redis Pub/Sub so instances behind a load balancer can notify each other's connected clients.

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
| `OPENCHAT_LOAD_USERS` | `100` | Distinct users for direct-message load |
| `OPENCHAT_LOAD_MESSAGES` | `2000` | Direct Store messages |
| `OPENCHAT_LOAD_GROUP_MEMBERS` | `150` | Members in the group fanout test |
| `OPENCHAT_LOAD_GROUP_MESSAGES` | `600` | Group messages |
| `OPENCHAT_LOAD_HTTP_MESSAGES` | `500` | Plug HTTP message sends |
| `OPENCHAT_LOAD_REDIS_MESSAGES` | `300` | Redis-backed message sends |
| `OPENCHAT_LOAD_REDIS_INDEX_MESSAGES` | `240` | Redis secondary-index write/read checks |
| `OPENCHAT_LOAD_CONCURRENCY` | `16` | Concurrent Store writer tasks |
| `OPENCHAT_LOAD_WORKER_MESSAGES` | `150` | Messages per concurrent Store writer |
| `OPENCHAT_LOAD_HTTP_CONCURRENCY` | `12` | Concurrent Plug HTTP writer tasks |
| `OPENCHAT_LOAD_HTTP_WORKER_MESSAGES` | `50` | Messages per concurrent HTTP writer |
| `OPENCHAT_LOAD_REDIS_CONCURRENCY` | `8` | Concurrent Redis-backed writer tasks |
| `OPENCHAT_LOAD_REDIS_WORKER_MESSAGES` | `60` | Messages per concurrent Redis writer |
| `OPENCHAT_LOAD_RECEIPT_CONCURRENCY` | `16` | Concurrent receipt writer tasks |
| `OPENCHAT_MIN_STORE_MSG_PER_SEC` | `300` | Minimum direct Store throughput |
| `OPENCHAT_MIN_GROUP_MSG_PER_SEC` | `100` | Minimum group-message throughput |
| `OPENCHAT_MIN_HTTP_MSG_PER_SEC` | `100` | Minimum Plug HTTP throughput |
| `OPENCHAT_MIN_REDIS_MSG_PER_SEC` | `20` | Minimum Redis-backed throughput |
| `OPENCHAT_MIN_CONCURRENT_STORE_MSG_PER_SEC` | `200` | Minimum concurrent Store throughput |
| `OPENCHAT_MIN_CONCURRENT_HTTP_MSG_PER_SEC` | `100` | Minimum concurrent Plug HTTP throughput |
| `OPENCHAT_MIN_CONCURRENT_REDIS_MSG_PER_SEC` | `20` | Minimum concurrent Redis throughput |
| `OPENCHAT_MIN_RECEIPT_PER_SEC` | `100` | Minimum concurrent receipt throughput |
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
