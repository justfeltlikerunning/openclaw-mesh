#!/usr/bin/env bash
# mesh-reply.sh - Reply to an incoming MESH request, auto-echoing correlationId and replyContext
#
# Usage: mesh-reply.sh "<original_envelope_json>" "<response_body>" [--subject "<subject>"]
#
# This is the EASY WAY to respond to MESH requests. It:
#   1. Extracts from, id, replyTo, and replyContext from the original envelope
#   2. Builds a proper response with correlationId and replyContext echoed back
#   3. Sends it to the original sender's replyTo URL
#   4. Falls back to mesh-send.sh if no replyTo URL
#
# Example:
#   mesh-reply.sh "$INCOMING_ENVELOPE" "Here are the Monday tasks: Task1, Task2, Task3"

set -euo pipefail

# Resolve script directory - handle cron environments where BASH_SOURCE may be empty
if [ -n "${BASH_SOURCE[0]:-}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
elif [ -n "${0:-}" ] && [ "$0" != "bash" ] && [ "$0" != "-bash" ] && [ "$0" != "sh" ]; then
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
else
    SCRIPT_DIR=""
fi

if [ -z "${MESH_HOME:-}" ]; then
    parent="$(dirname "$SCRIPT_DIR")"
    if [ -f "$parent/config/agent-registry.json" ]; then
        MESH_HOME="$parent"
    else
        MESH_HOME="$parent"
    fi
fi

# Agent identity
if [ -n "${MESH_AGENT:-}" ]; then
    MY_AGENT="$MESH_AGENT"
elif [ -f "$MESH_HOME/config/identity" ]; then
    MY_AGENT="$(cat "$MESH_HOME/config/identity" | tr -d '[:space:]')"
else
    MY_AGENT="${USER:-unknown}"
fi

AUDIT_LOG="$MESH_HOME/logs/mesh-audit.jsonl"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

if [[ $# -lt 2 ]]; then
    echo "Usage: mesh-reply.sh '<original_envelope_json>' '<response_body>' [--subject '<subject>']"
    echo ""
    echo "Automatically echoes correlationId and replyContext from the original message."
    exit 1
fi

ORIGINAL_ENVELOPE="$1"
RESPONSE_BODY="$2"
shift 2

SUBJECT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --subject) SUBJECT="$2"; shift 2 ;;
        *) shift ;;
    esac
done

# Parse original envelope
ORIG_FROM=$(echo "$ORIGINAL_ENVELOPE" | jq -r '.from // ""')
ORIG_ID=$(echo "$ORIGINAL_ENVELOPE" | jq -r '.id // ""')
REPLY_URL=$(echo "$ORIGINAL_ENVELOPE" | jq -r '.replyTo.url // ""')
REPLY_TOKEN=$(echo "$ORIGINAL_ENVELOPE" | jq -r '.replyTo.token // ""')
REPLY_CONTEXT=$(echo "$ORIGINAL_ENVELOPE" | jq -c '.replyContext // null')

if [[ -z "$ORIG_FROM" || "$ORIG_FROM" == "null" ]]; then
    echo -e "${RED}Cannot determine sender from original envelope${NC}" >&2
    exit 1
fi

# Auto-generate subject if not provided
if [[ -z "$SUBJECT" ]]; then
    SUBJECT=$(echo "$RESPONSE_BODY" | head -c 80)
fi

# Generate response envelope
RESP_ID="msg_$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
NONCE=$(openssl rand -hex 16 2>/dev/null || cat /proc/sys/kernel/random/uuid | tr -d '-')

# Build correlation
CORR_ID="null"
if [[ -n "$ORIG_ID" && "$ORIG_ID" != "null" ]]; then
    CORR_ID="\"$ORIG_ID\""
fi

# Build replyContext (echo back as-is, null if not present)
if [[ "$REPLY_CONTEXT" == "null" || -z "$REPLY_CONTEXT" ]]; then
    RC_JSON="null"
else
    RC_JSON="$REPLY_CONTEXT"
fi

ENVELOPE=$(jq -n -c \
    --arg protocol "mesh/1.0" \
    --arg id "$RESP_ID" \
    --arg ts "$TIMESTAMP" \
    --arg from "$MY_AGENT" \
    --arg to "$ORIG_FROM" \
    --argjson correlationId "$CORR_ID" \
    --argjson replyContext "$RC_JSON" \
    --arg nonce "$NONCE" \
    --arg subject "$SUBJECT" \
    --arg body "$RESPONSE_BODY" \
    '{
        protocol: $protocol,
        id: $id,
        timestamp: $ts,
        from: $from,
        to: $to,
        type: "response",
        correlationId: $correlationId,
        replyContext: $replyContext,
        nonce: $nonce,
        payload: {
            subject: $subject,
            body: $body
        }
    }')

# Try replyTo URL first (direct delivery)
if [[ -n "$REPLY_URL" && "$REPLY_URL" != "null" ]]; then
    HOOK_PAYLOAD=$(jq -n -c --arg message "$ENVELOPE" '{message: $message}')
    
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 10 \
        --max-time 30 \
        -X POST "$REPLY_URL" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${REPLY_TOKEN}" \
        -d "$HOOK_PAYLOAD" 2>/dev/null || echo "000")

    if [[ "$HTTP_CODE" =~ ^2[0-9][0-9]$ ]]; then
        # Audit log
        jq -n -c \
            --arg ts "$TIMESTAMP" \
            --arg from "$MY_AGENT" \
            --arg to "$ORIG_FROM" \
            --arg id "$RESP_ID" \
            --arg subject "$SUBJECT" \
            --arg body "$RESPONSE_BODY" \
            --arg corr "${ORIG_ID:-}" \
            --arg rc "$REPLY_CONTEXT" \
            '{ts:$ts, from:$from, to:$to, type:"response", id:$id, subject:$subject, body:$body, status:"sent", correlationId:$corr, replyContext:$rc}' \
            >> "$AUDIT_LOG"

        echo -e "${GREEN}✓ Reply sent to ${ORIG_FROM} via replyTo (HTTP ${HTTP_CODE}) - ${RESP_ID}${NC}" >&2
        echo "$RESP_ID"
        exit 0
    else
        echo -e "${YELLOW}⚠ replyTo URL failed (HTTP ${HTTP_CODE}), falling back to mesh-send.sh${NC}" >&2
    fi
fi

# Fallback: use mesh-send.sh
echo -e "${YELLOW}Using mesh-send.sh fallback${NC}" >&2
SEND_ARGS=("$ORIG_FROM" "response" "$RESPONSE_BODY")
if [[ -n "$ORIG_ID" && "$ORIG_ID" != "null" ]]; then
    SEND_ARGS+=(--correlation-id "$ORIG_ID")
fi
if [[ "$REPLY_CONTEXT" != "null" && -n "$REPLY_CONTEXT" ]]; then
    SEND_ARGS+=(--reply-context "$REPLY_CONTEXT")
fi
if [[ -n "$SUBJECT" ]]; then
    SEND_ARGS+=(--subject "$SUBJECT")
fi

bash "$SCRIPT_DIR/mesh-send.sh" "${SEND_ARGS[@]}"
