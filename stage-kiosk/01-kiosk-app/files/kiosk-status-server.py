#!/usr/bin/env python3
# Tiny loopback-only HTTP server exposing kiosk-launch.sh's current decision
# (/tmp/kiosk-status.json) to loading.html's JS. Exists because Chromium's
# fetch() doesn't support file:// URLs, and XHR-to-file:// needs a flag whose
# cross-version behavior isn't worth depending on - plain HTTP is unambiguous.

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
