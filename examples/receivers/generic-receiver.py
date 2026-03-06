#!/usr/bin/env python3
"""
MESH Generic Receiver - Framework-agnostic webhook endpoint.
Receives MESH protocol messages over HTTP and dispatches them to your handler.

Usage:
    python3 generic-receiver.py                    # Start on port 8900
    python3 generic-receiver.py --port 9000        # Custom port
    MESH_HANDLER=./my-handler.sh python3 generic-receiver.py  # Custom handler script

Works with: CrewAI, AutoGen, LangGraph, LangChain, custom agents, or any system
that can process JSON messages.

The handler receives the MESH envelope as a JSON string via stdin.
Return JSON to stdout to send a response back to the sender.
"""

import json
import os
import subprocess
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler
from datetime import datetime, timezone

MESH_HOME = os.environ.get("MESH_HOME", os.path.expanduser("~/.mesh"))
MESH_AGENT = os.environ.get("MESH_AGENT", "unknown")
HANDLER = os.environ.get("MESH_HANDLER", None)
LOG_FILE = os.path.join(MESH_HOME, "logs", "mesh-audit.jsonl")

# In-memory message store (for polling-based frameworks)
message_inbox = []
MAX_INBOX = 100


def log_message(envelope, status="received"):
    """Append to audit log."""
    try:
        os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
        entry = {
            "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z"),
            "from": envelope.get("from", "?"),
            "to": envelope.get("to", MESH_AGENT),
            "type": envelope.get("type", "?"),
            "id": envelope.get("id", "?"),
            "subject": envelope.get("payload", {}).get("subject", ""),
            "status": status,
        }
        with open(LOG_FILE, "a") as f:
            f.write(json.dumps(entry) + "\n")
    except Exception:
        pass


def dispatch_to_handler(envelope):
    """Send envelope to external handler script/process."""
    if not HANDLER:
        return None
    try:
        result = subprocess.run(
            [HANDLER],
            input=json.dumps(envelope),
            capture_output=True,
            text=True,
            timeout=30,
        )
        if result.returncode == 0 and result.stdout.strip():
            try:
                return json.loads(result.stdout.strip())
            except json.JSONDecodeError:
                return {"body": result.stdout.strip()}
        return None
    except Exception as e:
        print(f"[MESH] Handler error: {e}", file=sys.stderr)
        return None


class MeshHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # Suppress default access logs
        pass

    def do_POST(self):
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length).decode("utf-8")

        try:
            data = json.loads(body)
        except json.JSONDecodeError:
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b'{"error":"invalid JSON"}')
            return

        # Extract MESH envelope
        message_raw = data.get("message", "")
        try:
            envelope = json.loads(message_raw) if isinstance(message_raw, str) else message_raw
        except json.JSONDecodeError:
            envelope = {"payload": {"body": message_raw}}

        # Log it
        msg_id = envelope.get("id", "?")
        sender = envelope.get("from", "?")
        msg_type = envelope.get("type", "?")
        subject = envelope.get("payload", {}).get("subject", "")
        body_text = envelope.get("payload", {}).get("body", "")

        print(f"[MESH] {sender} → {MESH_AGENT} | {msg_type} | {subject[:60]}")
        log_message(envelope)

        # Store in inbox (for polling-based frameworks)
        message_inbox.append(envelope)
        if len(message_inbox) > MAX_INBOX:
            message_inbox.pop(0)

        # Dispatch to handler if configured
        response = dispatch_to_handler(envelope)

        # Send response back via replyTo if this was a request
        if response and msg_type == "request":
            reply_to = envelope.get("replyTo", {})
            if reply_to and reply_to.get("url"):
                self._send_reply(envelope, response, reply_to)

        # Acknowledge receipt
        self.send_response(202)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"ok": True, "id": msg_id}).encode())

    def do_GET(self):
        """GET /inbox - retrieve pending messages (for polling-based frameworks)."""
        if self.path == "/inbox":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({
                "messages": list(message_inbox),
                "count": len(message_inbox),
            }).encode())
            return

        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({
                "status": "ok",
                "agent": MESH_AGENT,
                "inbox": len(message_inbox),
            }).encode())
            return

        self.send_response(404)
        self.end_headers()

    def _send_reply(self, original, response, reply_to):
        """Send MESH response back to sender."""
        import urllib.request
        reply_envelope = {
            "protocol": "mesh/1.0",
            "id": f"msg_{os.urandom(16).hex()}",
            "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z"),
            "from": MESH_AGENT,
            "to": original.get("from", "?"),
            "type": "response",
            "correlationId": original.get("id"),
            "replyContext": original.get("replyContext"),
            "payload": {
                "subject": f"Re: {original.get('payload', {}).get('subject', '')}",
                "body": response.get("body", json.dumps(response)),
            },
        }
        try:
            req = urllib.request.Request(
                reply_to["url"],
                data=json.dumps({"message": json.dumps(reply_envelope)}).encode(),
                headers={
                    "Content-Type": "application/json",
                    "Authorization": f"Bearer {reply_to.get('token', '')}",
                },
                method="POST",
            )
            urllib.request.urlopen(req, timeout=10)
            print(f"[MESH] Reply sent to {original.get('from')}")
        except Exception as e:
            print(f"[MESH] Reply failed: {e}", file=sys.stderr)


def main():
    port = 8900
    for i, arg in enumerate(sys.argv[1:], 1):
        if arg == "--port" and i < len(sys.argv) - 1:
            port = int(sys.argv[i + 1])

    print(f"🐝 MESH Generic Receiver v2.0")
    print(f"   Agent:   {MESH_AGENT}")
    print(f"   Port:    {port}")
    print(f"   Handler: {HANDLER or '(none - inbox mode)'}")
    print(f"   Inbox:   GET http://0.0.0.0:{port}/inbox")
    print(f"   Health:  GET http://0.0.0.0:{port}/health")
    print()

    server = HTTPServer(("0.0.0.0", port), MeshHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[MESH] Shutting down")
        server.server_close()


if __name__ == "__main__":
    main()
