# Native iOS (CometChat SDK) — where this actually stands

The app ships the **direct-REST web client** in a `WKWebView`. The native
CometChat UIKit path is opt-in (`-SREUseNativeUIKit YES`) and **not shippable
yet**. This records exactly what works, what does not, and the traps that cost
the most time, so the next attempt starts from evidence rather than repeating
the investigation.

## Fixed, verified against production

Four defects, all ours, all now covered by tests in
`test/sre_chat/ios_login_contract_test.exs`:

| Defect | Symptom |
|---|---|
| `wsChannel` in the login response | SIGTRAP during login — presents as a hang |
| `extensions` entries without `enabled` | SIGTRAP during login |
| JWT header was the literal `local` | Socket never dialled at all |
| No tolerance for a doubled `/v3.0` prefix | Message fetch 404s; SDK callback hangs |

All four share one shape: **a field the JS SDK ignores and the Swift SDK force
unwraps or parses strictly.** That asymmetry is why they survived — the web
client works perfectly and hides every one.

The same four were fixed upstream in OpenChat (Lore-Hex/OpenChat#7).

## Works

* Login, conversation list, and message fetch over REST.
* The WebSocket **connects and stays connected** — but only against a
  handshake with no reverse proxy in it (see below).

## Does not work

1. **`fetchPrevious`'s completion handler never fires.** The request returns
   HTTP 200 and the callback is simply never called, so the send that follows
   it never happens. This is the blocker; the socket being up does not help.
2. **The first socket attempts still fail** (`badframe`, `notAnUpgrade`) before
   one settles. The SDK opens several in parallel and some trip.

## The proxy finding

Through Caddy, the SDK intermittently rejects our `101` and then **re-sends the
upgrade request on the already-upgraded socket** — captured at the byte level
with `tools/ws_relay.py`; the "frames" decode to ASCII `GET / HTTP/1.1`. Cowboy
correctly answers close `1002`, the SDK calls that a connection error, and
retries into a storm.

Caddy injects `Alt-Svc` and a duplicate `Server` into the handshake response
and **cannot be told not to** — `header_down` has no effect on a response whose
connection has already been hijacked for the upgrade.

Answering the handshake directly fixes it. `WS_TLS_PORT` starts a second
listener that terminates TLS itself (see `SREChat.Application`), off unless set:

```
WS_TLS_PORT=8443
WS_TLS_CERTFILE=/etc/srechat/tls/ws.crt
WS_TLS_KEYFILE=/etc/srechat/tls/ws.key
PUBLIC_WS_PORT=8443     # so CHAT_WSS_PORT points the SDK at it
```

Measured with that in place: `WS connected`, `connect() accepted`, and
`status=connected` continuously for 30s+, versus never staying up through the
proxy.

**It is deliberately not enabled.** The cert has to be copied out of Caddy's
volume by hand, so it does not survive renewal — the socket would break
silently. Wire up a renewal hook before relying on it, and note the port needs
a firewall rule.

## Traps

* **The SDK's `CometChat WS:` logging is a no-op in the shipped binary.**
  Absence of those lines is not evidence a code path was not reached. This sent
  the investigation in the wrong direction for a long stretch.
* **The keychain survives an app uninstall**, and the SDK caches settings
  there. Re-test on a genuinely clean device (`simctl erase`) or a stale cache
  masks the result.
* **`print()` is block-buffered to a pipe.** `simctl launch --console` loses
  SDK output; `--console-pty` gives a tty and line buffering.
* **Settings keys are `UPPER_SNAKE` on the wire.** The SDK's model uses
  camelCase *property* names mapped by CodingKeys, so both spellings appear in
  the binary. Serving camelCase leaves `chat_wss_port` nil and the socket dies
  silently at a guard inside `connect()`.
* `CHAT_HOST` must carry **neither a port nor a path** — either makes
  `wss://<host>:<port>` unparseable and the client force-unwraps nil.
