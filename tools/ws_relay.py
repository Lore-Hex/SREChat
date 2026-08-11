#!/usr/bin/env python3
"""Byte-level WebSocket relay for diagnosing frame-level failures.

Sits between Caddy and cowboy ON the host, where the traffic is already
plaintext, so no certificate or hostname rewriting is involved — the client
still talks to the real hostname on :443 and derives its socket host normally.

    ./ws_relay.py [listen_port] [upstream_port]      # defaults 4001 -> 4000

Point Caddy's websocket routes at the listen port, run the client, read the
log, then put Caddy back.

Logs FRAME HEADERS ONLY — FIN/RSV/opcode/mask/length, plus close-frame status
codes. Never payloads: the client's first frame is an auth frame carrying a
JWT whose claims embed the access passcode, and a diagnostic that prints it
writes the credential into a log file. The header bits are what identify a
protocol violation anyway:

    rsv1=1 with no negotiated permessage-deflate  -> cowboy :badframe
    masked=0 from the client                      -> cowboy :badframe
    opcode>=8 with len>125 or fin=0               -> cowboy :badframe
    opcode=0 with no preceding fragment           -> cowboy :badframe
"""

import socket
import sys
import threading
import time

LISTEN_PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 4001
UPSTREAM_PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 4000

OPCODES = {0: "cont", 1: "text", 2: "binary", 8: "close", 9: "ping", 10: "pong"}
_counter = 0
_lock = threading.Lock()


def log(msg):
    print(f"{time.strftime('%H:%M:%S')} {msg}", flush=True)


def read_http_head(sock):
    """Read up to and including the blank line ending the HTTP head."""
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(4096)
        if not chunk:
            return buf, b""
        buf += chunk
    head, _, rest = buf.partition(b"\r\n\r\n")
    return head + b"\r\n\r\n", rest


def parse_frames(cid, direction, buf, state):
    """Consume whole frames from buf, logging each. Returns leftover bytes.

    A frame can straddle TCP reads, so this keeps a buffer rather than
    assuming each recv() starts on a frame boundary — the naive version
    misreports header bits as soon as a frame is split.
    """
    while True:
        if len(buf) < 2:
            return buf

        # If the stream carries an HTTP request instead of frames, say so once
        # and name the request LINE only — headers carry the auth token.
        if not state.get("http_reported"):
            for verb in (b"GET ", b"POST ", b"PUT ", b"HEAD ", b"OPTIONS "):
                if buf.startswith(verb):
                    line = buf.split(b"\r\n", 1)[0].decode(errors="replace")[:120]
                    log(f"[{cid}] {direction} !! HTTP REQUEST ON UPGRADED SOCKET: {line}")
                    state["http_reported"] = True
                    break

        b0, b1 = buf[0], buf[1]
        fin = b0 >> 7
        rsv1, rsv2, rsv3 = (b0 >> 6) & 1, (b0 >> 5) & 1, (b0 >> 4) & 1
        opcode = b0 & 0x0F
        masked = b1 >> 7
        length = b1 & 0x7F
        offset = 2

        if length == 126:
            if len(buf) < offset + 2:
                return buf
            length = int.from_bytes(buf[offset:offset + 2], "big")
            offset += 2
        elif length == 127:
            if len(buf) < offset + 8:
                return buf
            length = int.from_bytes(buf[offset:offset + 8], "big")
            offset += 8

        if masked:
            if len(buf) < offset + 4:
                return buf
            mask = buf[offset:offset + 4]
            offset += 4
        else:
            mask = None

        if len(buf) < offset + length:
            return buf

        payload = buf[offset:offset + length]
        buf = buf[offset + length:]

        name = OPCODES.get(opcode, f"?{opcode}")
        extra = ""

        # Close frames carry a status code; that is diagnostic, not secret.
        if opcode == 8 and length >= 2:
            body = payload
            if mask:
                body = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
            extra = f" close_code={int.from_bytes(body[:2], 'big')}"
        elif opcode == 8:
            extra = f" close_code=(none,len={length})"

        # Flag exactly the conditions cowboy rejects.
        problems = []
        if rsv1 or rsv2 or rsv3:
            problems.append("RSV_SET")
        if direction == "C->S" and not masked:
            problems.append("UNMASKED_CLIENT_FRAME")
        if opcode >= 8 and (length > 125 or not fin):
            problems.append("BAD_CONTROL_FRAME")
        if opcode not in OPCODES:
            problems.append("UNKNOWN_OPCODE")
        if opcode == 0 and not state.get("fragmented"):
            problems.append("ORPHAN_CONTINUATION")

        if opcode in (1, 2):
            state["fragmented"] = not fin
        elif opcode == 0 and fin:
            state["fragmented"] = False

        flag = ("  <<< " + ",".join(problems)) if problems else ""
        log(f"[{cid}] {direction} {name:6} fin={fin} rsv={rsv1}{rsv2}{rsv3} "
            f"masked={masked} len={length}{extra}{flag}")


def pump(cid, direction, src, dst):
    buf = b""
    state = {}
    try:
        while True:
            chunk = src.recv(65536)
            if not chunk:
                break
            dst.sendall(chunk)
            buf = parse_frames(cid, direction, buf + chunk, state)
    except Exception as exc:  # noqa: BLE001 — a relay must not mask the cause
        log(f"[{cid}] {direction} pump ended: {exc!r}")
    finally:
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except Exception:
                pass


def handle(client):
    global _counter
    with _lock:
        _counter += 1
        cid = _counter

    upstream = socket.create_connection(("127.0.0.1", UPSTREAM_PORT), timeout=30)
    try:
        head, rest = read_http_head(client)
        if not head:
            return
        first_line = head.split(b"\r\n", 1)[0].decode(errors="replace")
        is_upgrade = b"upgrade: websocket" in head.lower()
        upstream.sendall(head + rest)

        if not is_upgrade:
            # Plain HTTP: relay both ways without frame parsing.
            threading.Thread(target=pump, args=(cid, "", upstream, client), daemon=True).start()
            pump(cid, "", client, upstream)
            return

        log(f"[{cid}] UPGRADE {first_line}")
        resp_head, resp_rest = read_http_head(upstream)
        status = resp_head.split(b"\r\n", 1)[0].decode(errors="replace")
        # Full response headers: these are server output, not credentials, and
        # a client that rejects a 101 is rejecting something in here.
        resp_lines = [l for l in resp_head.decode(errors="replace").split("\r\n") if l]
        log(f"[{cid}] RESPONSE {status}")
        for line in resp_lines[1:]:
            log(f"[{cid}]   < {line}")
        # And the request headers it answered, to catch a key/accept mismatch.
        for line in head.decode(errors="replace").split("\r\n")[1:]:
            if line and line.split(":")[0].lower() in (
                "sec-websocket-key", "sec-websocket-version", "connection",
                "upgrade", "sec-websocket-extensions", "host",
            ):
                log(f"[{cid}]   > {line}")
        client.sendall(resp_head + resp_rest)

        if "101" not in status:
            log(f"[{cid}] not an upgrade — relaying as plain HTTP")
            return

        t = threading.Thread(target=pump, args=(cid, "S->C", upstream, client), daemon=True)
        t.start()
        pump(cid, "C->S", client, upstream)
        log(f"[{cid}] closed")
    finally:
        for s in (client, upstream):
            try:
                s.close()
            except Exception:
                pass


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", LISTEN_PORT))
    srv.listen(128)
    log(f"ws_relay listening on 127.0.0.1:{LISTEN_PORT} -> 127.0.0.1:{UPSTREAM_PORT}")
    while True:
        client, _ = srv.accept()
        threading.Thread(target=handle, args=(client,), daemon=True).start()


if __name__ == "__main__":
    main()
