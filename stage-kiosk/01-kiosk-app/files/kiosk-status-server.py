#!/usr/bin/env python3
# Tiny loopback-only HTTP server exposing kiosk-launch.sh's current decision
# (/tmp/kiosk-status.json). kiosk-self-update.sh reads this to learn which
# dev/prod branch to pull without a separate check-in call of its own -
# loading.html no longer polls this itself (see kiosk-launch.sh's swap_to()
# for how on-screen tab changes actually happen now), but the endpoint is
# also just a handy `curl 127.0.0.1:8765/status.json` for debugging.

import http.server
import socketserver

STATUS_FILE = "/tmp/kiosk-status.json"
PORT = 8765


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            with open(STATUS_FILE, "rb") as f:
                body = f.read()
        except OSError:
            body = b'{"target": null, "channel": "prod"}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass


class Server(socketserver.TCPServer):
    allow_reuse_address = True


if __name__ == "__main__":
    with Server(("127.0.0.1", PORT), Handler) as httpd:
        httpd.serve_forever()
