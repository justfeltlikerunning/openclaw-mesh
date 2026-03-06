#!/usr/bin/env bash
# mesh-track.sh - Track MESH request/response pairs
#
# Usage:
#   mesh-track.sh status              Show all pending requests (no response received)
#   mesh-track.sh summary             Show request/response stats
#   mesh-track.sh check <msg-id>      Check if a specific request got a response
#
# Analyzes the audit log to match requests with their correlation-id responses.

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

AUDIT_LOG="$MESH_HOME/logs/mesh-audit.jsonl"

if [ ! -f "$AUDIT_LOG" ]; then
    echo "No audit log found at $AUDIT_LOG" >&2
    exit 1
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

case "${1:-status}" in
    status)
        echo -e "${YELLOW}Pending Requests (no response received):${NC}"
        echo ""
        
        # Get all sent requests
        requests=$(jq -r 'select(.type == "request" and .status == "sent") | .msgId // .id // "unknown"' "$AUDIT_LOG" 2>/dev/null | sort -u)
        
        # Get all correlation IDs from responses
        responses=$(jq -r 'select(.status == "received" and .correlationId != null) | .correlationId' "$AUDIT_LOG" 2>/dev/null | sort -u)
        
        pending=0
        answered=0
        
        while IFS= read -r req_id; do
            [ -z "$req_id" ] && continue
            if echo "$responses" | grep -qF "$req_id" 2>/dev/null; then
                answered=$((answered + 1))
            else
                pending=$((pending + 1))
                # Get request details
                details=$(jq -r "select((.msgId // .id) == \"$req_id\" and .type == \"request\" and .status == \"sent\") | \"\(.timestamp // \"?\") → \(.to) : \(.subject // .body[0:60] // \"-\")\"" "$AUDIT_LOG" 2>/dev/null | head -1)
                if [ -n "$details" ]; then
                    echo -e "  ${RED}⏳${NC} $details"
                    echo "     ID: $req_id"
                fi
            fi
        done <<< "$requests"
        
        echo ""
        echo -e "Answered: ${GREEN}${answered}${NC} | Pending: ${RED}${pending}${NC} | Total requests: $((answered + pending))"
        ;;
    
    summary)
        total=$(wc -l < "$AUDIT_LOG")
        sent=$(jq -r 'select(.status == "sent")' "$AUDIT_LOG" 2>/dev/null | jq -s 'length')
        received=$(jq -r 'select(.status == "received")' "$AUDIT_LOG" 2>/dev/null | jq -s 'length')
        failed=$(jq -r 'select(.status != "sent" and .status != "received")' "$AUDIT_LOG" 2>/dev/null | jq -s 'length')
        requests=$(jq -r 'select(.type == "request" and .status == "sent")' "$AUDIT_LOG" 2>/dev/null | jq -s 'length')
        notifications=$(jq -r 'select(.type == "notification" and .status == "sent")' "$AUDIT_LOG" 2>/dev/null | jq -s 'length')
        responses_received=$(jq -r 'select(.status == "received" and .correlationId != null)' "$AUDIT_LOG" 2>/dev/null | jq -s 'length')
        
        echo "📊 MESH Traffic Summary"
        echo "━━━━━━━━━━━━━━━━━━━━━━"
        echo "Total log entries:    $total"
        echo "Successfully sent:    $sent"
        echo "Received (inbound):   $received"
        echo "Failed:               $failed"
        echo ""
        echo "Requests sent:        $requests"
        echo "Notifications sent:   $notifications"
        echo "Responses received:   $responses_received"
        
        if [ "$requests" -gt 0 ]; then
            response_rate=$(( (responses_received * 100) / requests ))
            echo ""
            echo -e "Response rate:        ${response_rate}%"
        fi
        
        echo ""
        echo "By agent:"
        jq -r 'select(.status == "sent") | .to' "$AUDIT_LOG" 2>/dev/null | sort | uniq -c | sort -rn | while read count agent; do
            printf "  %-18s %s msgs\n" "$agent" "$count"
        done
        ;;
    
    check)
        msg_id="${2:-}"
        if [ -z "$msg_id" ]; then
            echo "Usage: mesh-track.sh check <message-id>" >&2
            exit 1
        fi
        
        # Find the request
        request=$(jq -r "select((.msgId // .id) == \"$msg_id\")" "$AUDIT_LOG" 2>/dev/null | head -1)
        if [ -z "$request" ]; then
            echo "Message $msg_id not found in audit log"
            exit 1
        fi
        
        # Check for response
        response=$(jq -r "select(.correlationId == \"$msg_id\")" "$AUDIT_LOG" 2>/dev/null | head -1)
        if [ -n "$response" ]; then
            echo -e "${GREEN}✓ Response received${NC}"
            echo "$response" | jq -r '"  From: \(.from)\n  Time: \(.timestamp)\n  Body: \(.body[0:100] // "-")"'
        else
            echo -e "${RED}⏳ No response yet${NC}"
            echo "$request" | jq -r '"  To: \(.to)\n  Sent: \(.timestamp)\n  Subject: \(.subject // "-")"'
        fi
        ;;
    
    *)
        echo "Usage: mesh-track.sh {status|summary|check <msg-id>}" >&2
        exit 1
        ;;
esac
