"""Minimal demo API for the secure container supply chain demo.

Intentionally trivial — the point of this repo is the *supply chain*
around the image, not the app itself.
"""
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({
            "service": "acr-supplychain-demo",
            "status": "ok",
            "version": os.environ.get("APP_VERSION", "1.0.0"),
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    HTTPServer(("0.0.0.0", port), Handler).serve_forever()
