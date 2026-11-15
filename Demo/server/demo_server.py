#!/usr/bin/env python3
"""The demo's server: a few routes the demo app writes to and reads from, with real sockets.

  POST /writes   stores the body under its Idempotency-Key, once; a repeat answers with the first result
  GET  /writes   {"stored": distinct writes, "deliveries": every POST that reached the server, "keys": [...]}
  GET  /items/ID {"id", "title", "served_at"}: what the app prefetches and opens offline
  POST /reset    forgets everything

Faults are not made here: the app's FaultInjectingTransport makes them, so this server only tells the truth about what
reached it. Standard library only.

  demo_server.py [--port 8787]
"""

from __future__ import annotations

import argparse
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

_lock = threading.Lock()
_writes: dict[str, dict[str, object]] = {}
_deliveries = 0


class Handler(BaseHTTPRequestHandler):
    """The four routes."""

    def do_GET(self) -> None:  # noqa: N802 - the standard library's name
        if self.path == "/writes":
            with _lock:
                body = {
                    "stored": len(_writes),
                    "deliveries": _deliveries,
                    "keys": sorted(_writes),
                }
            self._json(200, body)
        elif self.path.startswith("/items/"):
            item = self.path.removeprefix("/items/")
            self._json(
                200, {"id": item, "title": f"Item {item}", "served_at": time.time()}
            )
        else:
            self._json(404, {"error": {"code": "not_found"}})

    def do_POST(self) -> None:  # noqa: N802 - the standard library's name
        global _deliveries
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length)
        if self.path == "/reset":
            with _lock:
                _writes.clear()
                _deliveries = 0
            self._json(200, {"reset": True})
            return
        if self.path != "/writes":
            self._json(404, {"error": {"code": "not_found"}})
            return
        key = self.headers.get("Idempotency-Key")
        if not key:
            self._json(400, {"error": {"code": "missing_idempotency_key"}})
            return
        with _lock:
            _deliveries += 1
            first = _writes.get(key)
            if first is None:
                first = {
                    "id": key,
                    "text": body.decode("utf-8", "replace"),
                    "stored_at": time.time(),
                }
                _writes[key] = first
            answer = {**first, "deliveries": _deliveries, "stored": len(_writes)}
        self._json(200, answer)

    def _json(self, status: int, body: object) -> None:
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, format: str, *args: object) -> None:  # noqa: A002 - the standard library's name
        print(f"{self.address_string()} {format % args}", flush=True)


def main() -> None:
    """Serves until interrupted."""
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8787)
    port = parser.parse_args().port
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"demo server on http://127.0.0.1:{port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
