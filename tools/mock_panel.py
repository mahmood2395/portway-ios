#!/usr/bin/env python3
"""A stand-in for mikrotik-manager's peer API, for contract tests and manual runs.

Records every request as one JSON line (method, path, query, body) and answers like the real
panel does. Behaviour is chosen by the public key, so one server covers every case:

    pubkey starting "CONFLICT"  -> claim 409 {other_device_name}
    pubkey starting "GONE"      -> every endpoint 404 (the panel disowned the peer)
    pubkey starting "SUPERSEDE" -> heartbeat {active:false, superseded_by_device_name}
    anything else               -> 200s

    tools/mock_panel.py --port 8765 --log /tmp/panel.jsonl
"""
import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse


def make_handler(log_path, base_url):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def record(self, body):
            url = urlparse(self.path)
            with open(log_path, "a") as fh:
                fh.write(json.dumps({"method": self.command, "path": url.path,
                                     "query": {k: v[0] for k, v in parse_qs(url.query).items()},
                                     "body": body}) + "\n")
            return url

        def reply(self, status, payload=None):
            data = json.dumps(payload or {}).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            url = self.record(None)
            q = {k: v[0] for k, v in parse_qs(url.query).items()}
            key = q.get("pubkey", "")
            if url.path == "/api/peer/info":
                if key.startswith("GONE"):
                    return self.reply(404)
                return self.reply(200, {
                    "name": "Sara M.", "plan": "Premium 30 GB", "expiry": "2026-10-17",
                    "days_left": 23, "disabled": False, "online": True,
                    "total_bytes": 12_400_000_000, "quota_bytes": 30_000_000_000,
                    "panel_url": base_url, "endpoint_ip": "5.9.44.12",
                    "city": "Frankfurt", "country_code": "DE",
                })
            if url.path == "/api/app/latest":
                if q.get("platform") == "ios":
                    return self.reply(200, {"platform": "ios", "build": 999, "version": "9.9.9",
                                            "url": "https://apps.apple.com/app/id0", "notes": "test",
                                            "min_supported_build": 1})
                return self.reply(200, {"version_code": 533, "url": base_url + "/app.apk"})
            self.reply(404)

        def do_POST(self):
            length = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(length) or b"{}")
            url = self.record(body)
            key = body.get("pubkey", "")
            if key.startswith("GONE"):
                return self.reply(404)
            if url.path == "/api/peer/session/claim" and key.startswith("CONFLICT") and not body.get("takeover"):
                return self.reply(409, {"granted": False, "other_device_name": "Google Pixel 7",
                                        "other_since": 1790153024860})
            if url.path == "/api/peer/session/claim":
                return self.reply(200, {"granted": True})
            if url.path == "/api/peer/session/heartbeat":
                if key.startswith("SUPERSEDE"):
                    return self.reply(200, {"active": False, "superseded_by_device_name": "Google Pixel 7"})
                return self.reply(200, {"active": True})
            if url.path in ("/api/peer/device/register", "/api/peer/session/release"):
                return self.reply(200, {"ok": True})
            self.reply(404)

    return Handler


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--log", default="/tmp/portway-panel.jsonl")
    args = ap.parse_args()
    base = f"http://127.0.0.1:{args.port}"
    server = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(args.log, base))
    print(f"mock panel on {base}, logging to {args.log}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
