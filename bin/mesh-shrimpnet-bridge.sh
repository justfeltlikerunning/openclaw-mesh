#!/bin/bash
# mesh-shrimpnet-bridge.sh — Route MESH messages through ShrimpNet hub
# Uses /api/messages with targets to store AND deliver via ShrimpNet's pulse connections.
# Agent responses route back through pulse to the same conversationId.

set -euo pipefail

AGENT="$1"
ENVELOPE="$2"

SHRIMPNET_URL="${SHRIMPNET_URL:-http://localhost:3000}"

# Extract fields from MESH envelope
BODY=$(echo "$ENVELOPE" | jq -r '.payload.body // .body // ""' 2>/dev/null)
FROM=$(echo "$ENVELOPE" | jq -r '.from // ""' 2>/dev/null)

# Build conversation ID
if [ "$FROM" = "ltdan" ] || [ "$AGENT" = "ltdan" ]; then
  CONV_ID="mesh-broadcast-$(date +%Y%m%d)"
else
  PAIR=$(echo -e "${FROM}\n${AGENT}" | sort | tr '\n' '-' | sed 's/-$//')
  CONV_ID="mesh-${PAIR}"
fi

# Ensure the conversation exists with the agent as participant
curl -sf --max-time 5 -X POST "${SHRIMPNET_URL}/api/conversations" \
  -H "Content-Type: application/json" \
  -d "$(jq -n -c \
    --arg id "$CONV_ID" \
    --arg title "📢 Fleet Broadcasts" \
    --argjson participants "[\"${AGENT}\"]" \
    '{id: $id, title: $title, participants: $participants}'
  )" >/dev/null 2>&1 || true

curl -sf --max-time 5 -X POST "${SHRIMPNET_URL}/api/conversations/$(printf '%s' "$CONV_ID" | jq -sRr @uri)/participants" \
  -H "Content-Type: application/json" \
  -d "$(jq -n -c --arg agent_name "$AGENT" '{agent_name: $agent_name}')" >/dev/null 2>&1 || true

# Post message — sender is FROM (ltdan etc), delivered to agent via ShrimpNet pulse
# Using senderType "human" triggers postToAgent() which does pulse delivery
curl -sf --max-time 10 -X POST "${SHRIMPNET_URL}/api/messages" \
  -H "Content-Type: application/json" \
  -d "$(jq -n -c \
    --arg sender "$FROM" \
    --arg body "$BODY" \
    --arg conversationId "$CONV_ID" \
    --argjson targets "[\"${AGENT}\"]" \
    '{sender: $sender, senderType: "human", body: $body, conversationId: $conversationId, targets: $targets}'
  )" >/dev/null 2>&1 && exit 0

echo "ShrimpNet delivery failed" >&2
exit 1
