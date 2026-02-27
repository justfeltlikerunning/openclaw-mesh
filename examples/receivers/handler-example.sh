#!/bin/bash
# Example MESH handler script
# Receives MESH envelope as JSON on stdin, outputs response JSON to stdout.
#
# Set MESH_HANDLER=./handler-example.sh when running generic-receiver.py
#
# Input:  Full MESH envelope JSON (stdin)
# Output: Response JSON to stdout (optional - only for request type)

# Read the envelope
envelope=$(cat)

# Parse fields with jq
msg_type=$(echo "$envelope" | jq -r '.type // "?"')
from=$(echo "$envelope" | jq -r '.from // "?"')
body=$(echo "$envelope" | jq -r '.payload.body // ""')
subject=$(echo "$envelope" | jq -r '.payload.subject // ""')

echo "[Handler] Received ${msg_type} from ${from}: ${subject}" >&2

case "$msg_type" in
    request)
        # Process the request and return a response
        # Replace this with your actual logic (call an API, query a DB, etc.)
        echo "{\"body\": \"Got your request: ${subject}. Processing...\"}"
        ;;
    notification)
        # Just acknowledge - no response needed
        echo "[Handler] Notification noted" >&2
        ;;
    alert)
        # Handle alert (log, notify, escalate, etc.)
        echo "[Handler] ALERT: ${body}" >&2
        ;;
    *)
        echo "[Handler] Unknown type: ${msg_type}" >&2
        ;;
esac
