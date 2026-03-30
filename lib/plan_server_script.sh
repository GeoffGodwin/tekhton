#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# plan_server_script.sh — Python server script generator for browser planning
#
# Extracted from plan_server.sh to keep file sizes under the 300-line ceiling.
# Contains only the _write_plan_server_script() function which writes the
# embedded Python HTTP server to disk.
#
# Sourced by plan_server.sh. Do not run directly.
# =============================================================================

# _write_plan_server_script SCRIPT_PATH
# Writes the Python HTTP server script to the given path.
_write_plan_server_script() {
    local script_path="$1"

    cat > "$script_path" << 'PYTHON_SERVER_EOF'
"""Tekhton Planning Form HTTP Server.

Serves static files and handles POST /submit and POST /save-draft endpoints.
Writes answers to the YAML answer file using a simple JSON-to-YAML converter.
"""
import json
import os
import signal
import sys
from http.server import HTTPServer, SimpleHTTPRequestHandler

ANSWERS_FILE = os.environ["PLAN_ANSWERS_FILE"]
COMPLETION_FILE = os.environ["PLAN_COMPLETION_FILE"]


def json_to_yaml(data):
    """Convert a flat dict of section_id -> answer_text to YAML answer updates.

    Reads the existing YAML file line by line, replacing answer fields for
    sections present in the data dict. This preserves all other YAML structure.
    """
    if not os.path.isfile(ANSWERS_FILE):
        return

    with open(ANSWERS_FILE, "r", encoding="utf-8") as f:
        lines = f.readlines()

    output = []
    current_section = None
    in_answer_block = False
    skip_block_lines = False

    for line in lines:
        stripped = line.rstrip("\n")

        # Detect section start: "  section_id:"
        if (
            len(stripped) > 2
            and stripped[:2] == "  "
            and stripped[2] != " "
            and stripped.endswith(":")
            and not stripped.lstrip().startswith("#")
        ):
            candidate = stripped.strip().rstrip(":")
            if candidate.replace("_", "").isalnum():
                current_section = candidate
                in_answer_block = False
                skip_block_lines = False

        # Detect answer field in a section we're updating
        if (
            current_section in data
            and stripped.startswith("    answer:")
        ):
            answer_text = data[current_section]
            in_answer_block = True
            skip_block_lines = True

            if not answer_text or answer_text.strip() == "":
                output.append('    answer: ""\n')
            elif _needs_block_scalar(answer_text):
                output.append("    answer: |\n")
                for aline in answer_text.split("\n"):
                    output.append("      " + aline + "\n")
            else:
                output.append('    answer: "' + answer_text.replace('"', '\\"') + '"\n')
            continue

        # Skip old block scalar continuation lines
        if skip_block_lines:
            if stripped.startswith("      ") and not (
                len(stripped) > 4
                and stripped[:4] == "    "
                and stripped[4] != " "
                and stripped[4].isalpha()
            ):
                continue
            skip_block_lines = False
            in_answer_block = False

        output.append(line if line.endswith("\n") else line + "\n")

    # Atomic write
    tmp_path = ANSWERS_FILE + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as f:
        f.writelines(output)
    os.replace(tmp_path, ANSWERS_FILE)


def _needs_block_scalar(text):
    """Check if text needs YAML block scalar (|) format."""
    special = set(':\"\'|>[]{}#')
    return "\n" in text or any(c in special for c in text)


class PlanHandler(SimpleHTTPRequestHandler):
    """HTTP handler for planning form POST endpoints."""

    def do_POST(self):
        if self.path == "/submit":
            self._handle_answers(touch_completion=True)
        elif self.path == "/save-draft":
            self._handle_answers(touch_completion=False)
        else:
            self.send_error(404, "Not Found")

    def _handle_answers(self, touch_completion):
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length)

        try:
            data = json.loads(body)
        except (json.JSONDecodeError, ValueError) as exc:
            self.send_error(400, "Invalid JSON: " + str(exc))
            return

        if not isinstance(data, dict):
            self.send_error(400, "Expected JSON object")
            return

        json_to_yaml(data)

        if touch_completion:
            with open(COMPLETION_FILE, "w", encoding="utf-8") as f:
                f.write("done\n")

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        status = "submitted" if touch_completion else "saved"
        self.wfile.write(json.dumps({"status": status}).encode())

    def log_message(self, format, *args):
        """Suppress default stderr logging; write to log file instead."""
        log_path = os.environ.get("PLAN_SERVER_LOG", "")
        if log_path:
            with open(log_path, "a", encoding="utf-8") as f:
                f.write("[server] " + (format % args) + "\n")


def main():
    port = int(os.environ.get("PLAN_SERVER_PORT", "8787"))
    server = HTTPServer(("127.0.0.1", port), PlanHandler)

    def handle_signal(signum, frame):
        server.shutdown()
        sys.exit(0)

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    server.serve_forever()


if __name__ == "__main__":
    main()
PYTHON_SERVER_EOF
}
