#!/usr/bin/env python3
# Swaps kiosk-launch.sh's on-screen Chromium tab to a new URL as a real
# top-level navigation - no iframe, so a target site's own X-Frame-Options
# can't block it - without restarting the whole Chromium process (which is
# what causes the multi-second black/white flash on this hardware). Opens
# the new target as a background tab via Chromium's CDP HTTP endpoints,
# waits for it to actually finish loading (only possible over a CDP
# WebSocket - the HTTP endpoints can create/activate/close tabs but don't
# report load state), then activates it and closes whatever tab was up
# before. Hand-rolls the WebSocket client (stdlib only, no extra apt/pip
# package) since this is the one place that needs anything beyond the
# HTTP-only /json endpoints.
#
# On a load timeout this reveals the new tab anyway rather than leaving the
# old one showing forever - matching kiosk-launch.sh's own
# wait_for_loading_html_ready() philosophy of "give up and reveal anyway"
# rather than getting stuck.

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


def http_put(url, timeout=5):
    req = urllib.request.Request(url, method="PUT")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def http_put_json(url, timeout=5):
    return json.loads(http_put(url, timeout=timeout))


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


def wait_for_load(ws_url, timeout):
    sock, buf = ws_connect(ws_url, timeout)
    try:
        ws_send_text(sock, json.dumps({"id": 1, "method": "Page.enable"}))
        # A brand-new tab starts navigating the instant /json/new creates it,
        # before this script has even finished the WebSocket handshake - for
        # a tiny local file:// page (the fallback/loading pages) that's often
        # enough time for it to finish loading *before* Page.enable takes
        # effect, so Page.loadEventFired never fires for us to see (CDP
        # doesn't replay past events to a newly-enabled domain). Checking
        # document.readyState directly closes that race: if the page already
        # finished, this catches it instead of stalling out to the full
        # timeout for no reason. Confirmed reproducible locally (~1 in 5
        # swaps to a trivial local page) before this check was added.
        ws_send_text(sock, json.dumps({
            "id": 2,
            "method": "Runtime.evaluate",
            "params": {"expression": "document.readyState"},
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
                value = msg.get("result", {}).get("result", {}).get("value")
                if value == "complete":
                    return True
    finally:
        try:
            sock.close()
        except OSError:
            pass


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=9222)
    p.add_argument("--url", required=True)
    p.add_argument("--old-id", default="")
    p.add_argument("--timeout", type=float, default=15)
    args = p.parse_args()

    base = f"http://127.0.0.1:{args.port}"

    try:
        target = http_put_json(f"{base}/json/new?{urllib.parse.quote(args.url, safe='')}")
    except Exception as e:
        print(f"cdp-tab-swap: failed to open new tab: {e}", file=sys.stderr)
        sys.exit(1)

    new_id = target.get("id")
    ws_url = target.get("webSocketDebuggerUrl")
    if not new_id or not ws_url:
        print("cdp-tab-swap: /json/new response missing id/webSocketDebuggerUrl", file=sys.stderr)
        sys.exit(1)

    try:
        loaded = wait_for_load(ws_url, args.timeout)
    except Exception as e:
        print(f"cdp-tab-swap: error waiting for load ({e}), revealing anyway", file=sys.stderr)
        loaded = False
    if not loaded:
        print("cdp-tab-swap: timed out waiting for load, revealing anyway", file=sys.stderr)

    try:
        http_put(f"{base}/json/activate/{new_id}")
    except Exception as e:
        print(f"cdp-tab-swap: failed to activate new tab: {e}", file=sys.stderr)

    if args.old_id:
        try:
            http_put(f"{base}/json/close/{args.old_id}")
        except Exception as e:
            print(f"cdp-tab-swap: failed to close old tab {args.old_id}: {e}", file=sys.stderr)

    print(new_id)


if __name__ == "__main__":
    main()
