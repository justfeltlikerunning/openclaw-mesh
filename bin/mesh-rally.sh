#!/usr/bin/env bash
# mesh-rally.sh - MESH v3 Conversation Rally (Phase 4: Multi-turn with Shared Context)
# Sends a question to multiple agents as a threaded conversation.
# Supports follow-up rounds that embed prior responses as shared context.
#
# Usage: mesh-rally.sh "<message>" [options]
#
# Options:
#   --agents <list>     Comma-separated agent names (default: all)
#   --file <path>       Attach a file to the request
#   --subject <text>    Subject line
#   --ttl <seconds>     Time-to-live per round (default: 300)
#   --priority <level>  high|normal|low
#   --conv-id <id>      Continue existing conversation (follow-up round)
#
# Examples:
#   mesh-rally.sh "Count active records" --agents "agent-a,agent-b"
#   mesh-rally.sh "Now count related records" --conv-id "conv_abc123" --agents "agent-a,agent-b"
#   mesh-rally.sh "Consensus?" --conv-id "conv_abc123" --agents "agent-a,agent-b"

set -euo pipefail

# Resolve script directory
if [ -n "${BASH_SOURCE[0]:-}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
elif [ -n "${0:-}" ] && [ "$0" != "bash" ] && [ "$0" != "-bash" ] && [ "$0" != "sh" ]; then
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
else
    SCRIPT_DIR=""
fi
if [ -z "${MESH_HOME:-}" ]; then
    if [ -n "$SCRIPT_DIR" ]; then
        MESH_HOME="$(dirname "$SCRIPT_DIR")"
    elif [ -f "$HOME/openclaw-mesh/config/agent-registry.json" ]; then
        MESH_HOME="$HOME/openclaw-mesh"
    else
        echo "ERROR: Cannot determine MESH_HOME. Set MESH_HOME env var." >&2
        exit 1
    fi
fi

if [ -n "${MESH_AGENT:-}" ]; then
    MY_AGENT="$MESH_AGENT"
elif [ -f "$MESH_HOME/config/identity" ]; then
    MY_AGENT="$(cat "$MESH_HOME/config/identity" | tr -d '[:space:]')"
else
    MY_AGENT="${USER:-unknown}"
fi

MESSAGE="${1:-}"
shift || true

AGENTS="all"
FILE=""
SUBJECT=""
TTL=300
PRIORITY="normal"
CONV_ID=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --agents)   AGENTS="$2"; shift 2 ;;
        --file)     FILE="$2"; shift 2 ;;
        --subject)  SUBJECT="$2"; shift 2 ;;
        --ttl)      TTL="$2"; shift 2 ;;
        --priority) PRIORITY="$2"; shift 2 ;;
        --conv-id)  CONV_ID="$2"; shift 2 ;;
        *) shift ;;
    esac
done

if [[ -z "$MESSAGE" ]]; then
    echo "Usage: mesh-rally.sh \"<message>\" [--agents <list>] [--file <path>]"
    exit 1
fi

[[ -z "$SUBJECT" ]] && SUBJECT="$(echo "$MESSAGE" | head -c 80)"

# Build target list
if [[ "$AGENTS" == "all" ]]; then
    TARGETS=$(jq -r --arg me "$MY_AGENT" '.agents | keys[] | select(. != $me)' "$MESH_HOME/config/agent-registry.json")
else
    TARGETS=$(echo "$AGENTS" | tr ',' '\n')
fi
TARGET_LIST=$(echo "$TARGETS" | tr '\n' ',' | sed 's/,$//' | sed 's/  */,/g')
TARGET_COUNT=$(echo "$TARGETS" | grep -c .)

# Generate or reuse conversation ID
IS_FOLLOWUP=false
if [[ -z "$CONV_ID" ]]; then
    CONV_ID="conv_$(date +%s)_$(head -c 4 /dev/urandom | xxd -p)"
else
    IS_FOLLOWUP=true
fi

# Create conversation state directory
CONV_DIR="$MESH_HOME/state/conversations"
mkdir -p "$CONV_DIR"
CONV_FILE="$CONV_DIR/${CONV_ID}.json"
AUDIT_LOG="$MESH_HOME/logs/mesh-audit.jsonl"
mkdir -p "$(dirname "$AUDIT_LOG")"
NOW="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"

# ── Build shared context from prior rounds ──
SHARED_CONTEXT=""
ROUND=1
if [[ "$IS_FOLLOWUP" == true && -f "$CONV_FILE" ]]; then
    # Calculate round number
    ROUND=$(jq '.rounds | length + 1' "$CONV_FILE" 2>/dev/null || echo 1)
    
    # Build shared context using external script (avoids bash quoting issues with inline python)
    SHARED_CONTEXT=$(python3 "$SCRIPT_DIR/mesh-conv-context.py" "$CONV_FILE" 2>/dev/null || echo "")
fi

# ── Initialize or update conversation state ──
if [[ ! -f "$CONV_FILE" ]]; then
    # New conversation
    jq -n \
        --arg id "$CONV_ID" \
        --arg from "$MY_AGENT" \
        --arg question "$MESSAGE" \
        --arg subject "$SUBJECT" \
        --arg participants "$TARGET_LIST" \
        --argjson expected "$TARGET_COUNT" \
        --arg status "active" \
        --arg ts "$NOW" \
        --argjson ttl "$TTL" \
        '{
            conversationId: $id,
            type: "rally",
            from: $from,
            question: $question,
            subject: $subject,
            participants: ($participants | split(",")),
            expectedResponses: $expected,
            receivedResponses: 0,
            responses: [],
            rounds: [{
                round: 1,
                question: $question,
                ts: $ts,
                responses: [],
                status: "pending",
                expectedResponses: $expected,
                receivedResponses: 0
            }],
            currentRound: 1,
            status: $status,
            createdAt: $ts,
            updatedAt: $ts,
            ttl: $ttl,
            expiresAt: (($ts | split(".")[0] + "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime + $ttl | strftime("%Y-%m-%dT%H:%M:%S.000Z"))
        }' > "$CONV_FILE"
else
    # Follow-up round - archive current round's responses and start new round
    python3 -c "
import json, sys
from datetime import datetime, timezone, timedelta

with open('$CONV_FILE') as f:
    conv = json.load(f)

# Close current round if it has responses
rounds = conv.get('rounds', [])
if rounds:
    last = rounds[-1]
    if last.get('status') == 'pending' or last.get('status') == 'partial':
        last['status'] = 'superseded'  # New round started before completion

# Add new round
new_round = {
    'round': len(rounds) + 1,
    'question': '''$(echo "$MESSAGE" | sed "s/'/\\\\'/g")''',
    'ts': '$NOW',
    'responses': [],
    'status': 'pending',
    'expectedResponses': $TARGET_COUNT,
    'receivedResponses': 0
}
rounds.append(new_round)
conv['rounds'] = rounds
conv['currentRound'] = len(rounds)
conv['status'] = 'active'
conv['updatedAt'] = '$NOW'
conv['expectedResponses'] = $TARGET_COUNT
conv['receivedResponses'] = 0

# Update expiry
now = datetime.now(timezone.utc)
conv['expiresAt'] = (now + timedelta(seconds=$TTL)).strftime('%Y-%m-%dT%H:%M:%S.000Z')

with open('$CONV_FILE', 'w') as f:
    json.dump(conv, f, indent=2)

print(f'Round {len(rounds)} started')
" 2>&1
fi

# Display
if [[ "$IS_FOLLOWUP" == true ]]; then
    echo "🐝  MESH Rally Follow-up [${CONV_ID}] Round ${ROUND}"
else
    echo "🐝  MESH Rally [${CONV_ID}] Round 1"
fi
echo "    To: ${TARGET_LIST}"
echo "    Q:  $(echo "$MESSAGE" | head -c 100)"
[[ -n "$SHARED_CONTEXT" ]] && echo "    📋 Shared context from ${ROUND} prior round(s)"
echo "---"

# Log to audit
RALLY_TYPE="rally/open"
[[ "$IS_FOLLOWUP" == true ]] && RALLY_TYPE="rally/followup"
jq -n -c \
    --arg ts "$NOW" \
    --arg conv "$CONV_ID" \
    --arg from "$MY_AGENT" \
    --arg participants "$TARGET_LIST" \
    --arg subject "$SUBJECT" \
    --arg body "$MESSAGE" \
    --argjson expected "$TARGET_COUNT" \
    --argjson round "$ROUND" \
    --arg type "$RALLY_TYPE" \
    '{
        ts: $ts,
        conversationId: $conv,
        type: $type,
        from: $from,
        participants: ($participants | split(",")),
        subject: $subject,
        body: ($body | .[0:200]),
        expectedResponses: $expected,
        round: $round,
        status: "pending"
    }' >> "$AUDIT_LOG"

# ── Send to each agent ──
SENT=0
FAILED=0

for agent in $TARGETS; do
    EXTRA_ARGS=""
    [[ -n "$FILE" ]] && EXTRA_ARGS="--file $FILE"
    
    # Build the message body with shared context
    FULL_MSG="$MESSAGE"
    if [[ -n "$SHARED_CONTEXT" ]]; then
        FULL_MSG="${SHARED_CONTEXT}

── Round ${ROUND} (current) ──
${MESSAGE}"
    fi
    
    # Pass conversation context via reply-context
    REPLY_CTX=$(jq -n -c \
        --arg conv "$CONV_ID" \
        --arg participants "$TARGET_LIST" \
        --argjson round "$ROUND" \
        '{conversationId: $conv, participants: ($participants | split(",")), round: $round}')
    
    if bash "$SCRIPT_DIR/mesh-send.sh" "$agent" request "$FULL_MSG" \
        --subject "[$CONV_ID] $SUBJECT" \
        --conversation-id "$CONV_ID" \
        --ttl "$TTL" \
        --priority "$PRIORITY" \
        --reply-context "$REPLY_CTX" \
        --no-retry \
        $EXTRA_ARGS 2>&1; then
        SENT=$((SENT + 1))
    else
        FAILED=$((FAILED + 1))
    fi
done

echo "---"
echo "🐝  Rally complete: ${SENT} sent, ${FAILED} failed [${CONV_ID}] Round ${ROUND}"

# Update conversation state
if [[ -f "$CONV_FILE" ]]; then
    jq --argjson sent "$SENT" --argjson failed "$FAILED" \
        '.sentCount = $sent | .failedCount = $failed' \
        "$CONV_FILE" > "${CONV_FILE}.tmp" && mv "${CONV_FILE}.tmp" "$CONV_FILE"
fi
