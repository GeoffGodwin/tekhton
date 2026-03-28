#!/usr/bin/env python3
"""Watchtower Server — lightweight HTTP server for Watchtower interactive controls.

Serves the dashboard static files and provides a /api/submit endpoint for writing
files to .claude/watchtower_inbox/. Binds to localhost only for security.

Usage:
    python3 tools/watchtower_server.py [--port PORT] [--dashboard-dir DIR] [--inbox-dir DIR]

Defaults:
    --port 8271
    --dashboard-dir .claude/dashboard
    --inbox-dir .claude/watchtower_inbox
"""

import argparse
import http.server
import json
import os
import re
import sys


class WatchtowerHandler(http.server.SimpleHTTPRequestHandler):
    """HTTP handler that serves static files and handles inbox submissions."""

    inbox_dir = ""

    def do_GET(self):
        if self.path == "/api/ping":
            self._json_response(200, {"ok": True})
            return
        super().do_GET()

    def do_POST(self):
        if self.path == "/api/submit":
            self._handle_submit()
            return
        self._json_response(404, {"error": "Not found"})

    def _handle_submit(self):
        try:
            length = int(self.headers.get("Content-Length", 0))
            if length > 100000:  # 100KB safety limit
                self._json_response(413, {"error": "Payload too large"})
                return
            body = self.rfile.read(length)
            data = json.loads(body)
        except (json.JSONDecodeError, ValueError):
            self._json_response(400, {"error": "Invalid JSON"})
            return

        filename = data.get("filename", "")
        content = data.get("content", "")

        if not filename or not content:
            self._json_response(400, {"error": "filename and content required"})
            return

        # Security: validate filename to prevent directory traversal
        basename = os.path.basename(filename)
        if basename != filename or ".." in filename or "/" in filename or "\\" in filename:
            self._json_response(400, {"error": "Invalid filename"})
            return

        # Only allow expected file patterns
        if not re.match(r"^(note_|milestone_|manifest_append_|task_)\S+\.(md|cfg|txt)$", basename):
            self._json_response(400, {"error": "Unexpected filename pattern"})
            return

        # Ensure inbox directory exists
        os.makedirs(self.inbox_dir, exist_ok=True)

        filepath = os.path.join(self.inbox_dir, basename)
        if os.path.exists(filepath):
            self._json_response(409, {"error": "File already exists"})
            return

        try:
            with open(filepath, "w", encoding="utf-8") as f:
                f.write(content)
            self._json_response(201, {"ok": True, "file": basename})
        except OSError as e:
            self._json_response(500, {"error": str(e)})

    def _json_response(self, code, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        """Handle CORS preflight."""
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def log_message(self, fmt, *args):
        sys.stderr.write("[watchtower] %s\n" % (fmt % args))


def main():
    parser = argparse.ArgumentParser(description="Watchtower HTTP server")
    parser.add_argument("--port", type=int, default=8271, help="Port to bind (default: 8271)")
    parser.add_argument("--dashboard-dir", default=".claude/dashboard", help="Dashboard directory to serve")
    parser.add_argument("--inbox-dir", default=".claude/watchtower_inbox", help="Inbox directory for submissions")
    args = parser.parse_args()

    dashboard_dir = os.path.abspath(args.dashboard_dir)
    inbox_dir = os.path.abspath(args.inbox_dir)

    if not os.path.isdir(dashboard_dir):
        sys.stderr.write("Error: dashboard directory not found: %s\n" % dashboard_dir)
        sys.stderr.write("Run a pipeline first or use --init to create it.\n")
        sys.exit(1)

    WatchtowerHandler.inbox_dir = inbox_dir

    os.chdir(dashboard_dir)
    # Bind to localhost only — never expose to 0.0.0.0
    server = http.server.HTTPServer(("127.0.0.1", args.port), WatchtowerHandler)
    sys.stderr.write("Watchtower server running at http://127.0.0.1:%d\n" % args.port)
    sys.stderr.write("Dashboard: %s\n" % dashboard_dir)
    sys.stderr.write("Inbox:     %s\n" % inbox_dir)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        sys.stderr.write("\nShutting down.\n")
        server.server_close()


if __name__ == "__main__":
    main()
