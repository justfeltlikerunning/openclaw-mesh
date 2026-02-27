#!/bin/bash
# mesh-consensus-set.sh - Initiator sets consensus verdict on a conversation
# Usage: mesh-consensus-set.sh <conv_id> <verdict> [summary]
# Verdicts: match, near_match, close, disagree, resolved, inconclusive
#
# The conversation initiator (the agent who started the rally/collab/opinion)
# reviews all responses and makes the final call on consensus.

CONV_ID="$1"
VERDICT="$2"
SUMMARY="${3:-}"

[[ -z "$CONV_ID" || -z "$VERDICT" ]] && {
    echo "Usage: mesh-consensus-set.sh <conv_id> <verdict> [summary]"
    echo "Verdicts: match | near_match | close | disagree | resolved | inconclusive"
    exit 1
}

MESH_HOME="${MESH_HOME:-$HOME/clawd/openclaw-mesh}"

# Get the initiator's dashboard IP from the conversation file
CONV_FILE="$MESH_HOME/state/conversations/${CONV_ID}.json"
if [[ ! -f "$CONV_FILE" ]]; then
    echo "Conversation $CONV_ID not found"
    exit 1
fi

FROM=$(jq -r '.from' "$CONV_FILE")

# Look up dashboard IP (initiator's machine)
REGISTRY="$MESH_HOME/config/agent-registry.json"
DASH_IP=$(jq -r --arg agent "$FROM" '.agents[$agent].ip // "192.168.1.106"' "$REGISTRY" 2>/dev/null)

# Build JSON payload
PAYLOAD=$(jq -n -c \
    --arg conv "$CONV_ID" \
    --arg verdict "$VERDICT" \
    --arg summary "$SUMMARY" \
    '{conversationId: $conv, verdict: $verdict, summary: $summary}')

RESULT=$(curl -s --connect-timeout 3 --max-time 5 \
    -X POST "http://${DASH_IP}:8880/api/mesh/consensus" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" 2>/dev/null)

OK=$(echo "$RESULT" | jq -r '.ok // false')
if [[ "$OK" == "true" ]]; then
    echo "✅ Consensus set: $VERDICT on $CONV_ID"
    [[ -n "$SUMMARY" ]] && echo "   Summary: $SUMMARY"
else
    echo "❌ Failed: $(echo "$RESULT" | jq -r '.error // "unknown"')"
fi

# Also update local state
if [[ -f "$CONV_FILE" ]]; then
    jq --arg v "$VERDICT" --arg s "$SUMMARY" \
        '(.rounds[-1].consensus = $v) | (if $s != "" then .rounds[-1].consensusSummary = $s else . end)' \
        "$CONV_FILE" > "${CONV_FILE}.tmp" && mv "${CONV_FILE}.tmp" "$CONV_FILE"
fi
