#!/usr/bin/env python3
# Navigates kiosk-launch.sh's one existing Chromium tab to a new URL in
# place, as a real top-level navigation - no iframe, so a target site's own
# X-Frame-Options can't block it.
#
# This used to open the new target as a *second* tab (via Chromium's CDP
# /json/new, then activate/close), so the process never had to fully
# restart and there was no black/white relaunch flash. That broke on real
# hardware: --kiosk mode's chrome-less, fullscreen styling only applies to
# the one window Chromium creates at launch from the --kiosk command-line
# flag - a tab or window spun up afterward via DevTools Protocol doesn't
# inherit it, so it opened as an ordinary window with the OS's window
# frame and Chromium's own tab strip/address bar visible, confirmed live
# on the dev unit (2026-08-25). Navigating the one tab that was actually
# launched with --kiosk in place can't hit that bug - no second
# window/tab is ever created. Trade-off: switching targets shows a brief
# loading moment again, but it's just a page navigation on an
# already-warm renderer, nowhere near the multi-second cold-start flash a
# full Chromium relaunch causes on this hardware.
#
# Chromium's HTTP-only /json endpoints can't drive Page.navigate or report
# load state - only a real CDP WebSocket connection can - hence hand-rolling
# a minimal client here (stdlib only, no extra apt/pip package).

import argparse
import base64
import hashlib
import json
import os
import socket
import struct
import sys
import time
import urllib.parse
import urllib.request

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def http_get_json(url, timeout=5):
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return json.loads(r.read())


def find_ws_url(port, tab_id, timeout):
    targets = http_get_json(f"http://127.0.0.1:{port}/json", timeout=timeout)
    for t in targets:
        if t.get("id") == tab_id:
            return t.get("webSocketDebuggerUrl")
    return None


def ws_connect(ws_url, timeout):
    parsed = urllib.parse.urlparse(ws_url)
    host = parsed.hostname
    port = parsed.port or 80
    path = parsed.path or "/"
    if parsed.query:
        path += "?" + parsed.query
    sock = socket.create_connection((host, port), timeout=timeout)
    key = base64.b64encode(os.urandom(16)).decode()
    req = (
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        "\r\n"
    )
    sock.sendall(req.encode())
    resp = b""
    while b"\r\n\r\n" not in resp:
        chunk = sock.recv(4096)
        if not chunk:
            raise ConnectionError("socket closed during handshake")
        resp += chunk
    header, _, rest = resp.partition(b"\r\n\r\n")
    status_line = header.split(b"\r\n", 1)[0]
    if b"101" not in status_line:
        raise ConnectionError(f"handshake failed: {status_line!r}")
    expected = base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest())
    if expected not in header:
        raise ConnectionError("Sec-WebSocket-Accept mismatch")
    return sock, rest


def ws_send_text(sock, payload):
    data = payload.encode()
    length = len(data)
    mask = os.urandom(4)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
    if length <= 125:
        header = struct.pack("!BB", 0x81, 0x80 | length)
    elif length <= 0xFFFF:
        header = struct.pack("!BBH", 0x81, 0x80 | 126, length)
    else:
        header = struct.pack("!BBQ", 0x81, 0x80 | 127, length)
    sock.sendall(header + mask + masked)


def ws_read_frame(sock, buf):
    def need(n):
        nonlocal buf
        while len(buf) < n:
            chunk = sock.recv(65536)
            if not chunk:
                raise ConnectionError("socket closed")
            buf += chunk

    need(2)
    b1, b2 = buf[0], buf[1]
    opcode = b1 & 0x0F
    masked = b2 & 0x80
    length = b2 & 0x7F
    pos = 2
    if length == 126:
        need(pos + 2)
        length = struct.unpack("!H", buf[pos:pos + 2])[0]
        pos += 2
    elif length == 127:
        need(pos + 8)
        length = struct.unpack("!Q", buf[pos:pos + 8])[0]
        pos += 8
    mask_key = b""
    if masked:
        need(pos + 4)
        mask_key = buf[pos:pos + 4]
        pos += 4
    need(pos + length)
    payload = buf[pos:pos + length]
    if masked:
        payload = bytes(b ^ mask_key[i % 4] for i, b in enumerate(payload))
    rest = buf[pos + length:]
    return opcode, payload, rest


def navigate_and_wait(ws_url, target_url, timeout):
    sock, buf = ws_connect(ws_url, timeout)
    try:
        # Sent back-to-back on the same connection, not awaited individually -
        # Chromium processes CDP commands on a connection in the order
        # received, so Page.enable is guaranteed to take effect before
        # Page.navigate runs, which means the load it triggers is guaranteed
        # to be observable to us. No enable-vs-navigate race to cover here,
        # unlike the old open-a-new-tab approach where the tab could start
        # loading before we'd even connected.
        ws_send_text(sock, json.dumps({"id": 1, "method": "Page.enable"}))
        ws_send_text(sock, json.dumps({
            "id": 2,
            "method": "Page.navigate",
            "params": {"url": target_url},
        }))
        deadline = time.time() + timeout
        while True:
            remaining = deadline - time.time()
            if remaining <= 0:
                return False
            sock.settimeout(remaining)
            try:
                opcode, payload, buf = ws_read_frame(sock, buf)
            except socket.timeout:
                return False
            if opcode == 0x8:  # close frame
                return False
            if opcode != 0x1:  # not a text frame
                continue
            try:
                msg = json.loads(payload.decode("utf-8"))
            except ValueError:
                continue
            if msg.get("method") == "Page.loadEventFired":
                return True
            if msg.get("id") == 2:
                error = msg.get("result", {}).get("errorText")
                if error:
                    raise RuntimeError(f"Page.navigate failed: {error}")
    finally:
        try:
            sock.close()
        except OSError:
            pass


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=9222)
    p.add_argument("--tab-id", required=True)
    p.add_argument("--url", required=True)
    p.add_argument("--timeout", type=float, default=15)
    args = p.parse_args()

    try:
        ws_url = find_ws_url(args.port, args.tab_id, args.timeout)
    except Exception as e:
        print(f"cdp-navigate: failed to look up tab {args.tab_id}: {e}", file=sys.stderr)
        sys.exit(1)

    if not ws_url:
        print(f"cdp-navigate: tab {args.tab_id} not found", file=sys.stderr)
        sys.exit(1)

    try:
        loaded = navigate_and_wait(ws_url, args.url, args.timeout)
    except Exception as e:
        print(f"cdp-navigate: {e}", file=sys.stderr)
        sys.exit(1)

    if not loaded:
        print("cdp-navigate: timed out waiting for load, leaving it showing anyway", file=sys.stderr)

    sys.exit(0)


if __name__ == "__main__":
    main()
