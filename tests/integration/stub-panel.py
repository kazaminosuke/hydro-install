#!/usr/bin/env python3
"""Minimal stand-in for the Pterodactyl/Hydrodactyl panel API used by Wings.

Only for disposable integration tests. It serves the node configuration that
`wings configure` downloads and the remote endpoints Wings calls on boot, and
logs every request to $STUB_PANEL_LOG so tests can assert what was called.
"""
import json, os, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("STUB_PANEL_PORT", "8081"))
LOG = os.environ.get("STUB_PANEL_LOG", "/tmp/stub-panel.log")
URL = f"http://127.0.0.1:{PORT}"

NODE_CONFIG = {
    "debug": False,
    "uuid": "6f1c3b0e-0000-4000-8000-000000000001",
    "token_id": "stubtokenid000001",
    "token": "stub" * 16,
    "api": {"host": "0.0.0.0", "port": 8080,
            "ssl": {"enabled": False, "cert": "", "key": ""}, "upload_limit": 100},
    "system": {"data": "/var/lib/pterodactyl/volumes", "sftp": {"bind_port": 2022}},
    "allowed_mounts": [],
    "remote": URL,
}


class H(BaseHTTPRequestHandler):
    def _send(self, code, body=None):
        data = b"" if body is None else json.dumps(body, separators=(",", ":")).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _log(self):
        with open(LOG, "a") as f:
            f.write(f"{self.command} {self.path}\n")

    def _handle(self):
        self._log()
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        path = self.path.split("?")[0]
        if path.endswith("/configuration") and "/api/application/nodes/" in path:
            return self._send(200, NODE_CONFIG)
        if path == "/api/remote/servers":
            return self._send(200, {"data": [], "links": {}, "meta": {
                "current_page": 1, "from": 0, "last_page": 1, "per_page": 50,
                "to": 0, "total": 0}})
        if path == "/api/remote/servers/reset":
            return self._send(204)
        if path == "/api/application/locations":
            if self.command == "POST":
                return self._send(201, {"object": "location", "attributes": {"id": 1, "short": "XX"}})
            return self._send(200, {"data": [], "meta": {"pagination": {"total": 0}}})
        if path == "/api/application/nodes" and self.command == "POST":
            return self._send(201, {"object": "node", "attributes": {"id": 1}})
        if path.endswith("/allocations") and self.command == "POST":
            return self._send(204)
        if path == "/api/health":
            return self._send(200, {"status": "ok"})
        return self._send(200, {})

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = _handle

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
