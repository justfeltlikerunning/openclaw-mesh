#!/usr/bin/env bash
# mesh-conv-update.sh - Update conversation state when a MESH response arrives
# Phase 4: Round-aware response tracking
# Usage: mesh-conv-update.sh <conversation_id> <from_agent> [body_preview]
set -euo pipefail

CONV_ID="${1:-}"
FROM_AGENT="${2:-}"
BODY="${3:-}"

[[ -z "$CONV_ID" ]] && { echo "Usage: mesh-conv-update.sh <conv_id> <from_agent> [body]"; exit 1; }

MESH_HOME="${MESH_HOME:-$HOME/clawd/openclaw-mesh}"
CONV_DIR="$MESH_HOME/state/conversations"
CONV_FILE="$CONV_DIR/${CONV_ID}.json"

[[ -f "$CONV_FILE" ]] || { echo "No conversation file for $CONV_ID"; exit 0; }

NOW=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")

# Update the conversation state - round-aware
python3 -c "
import json, sys

conv_file = '$CONV_FILE'
from_agent = '$FROM_AGENT'
body = '''$(echo "$BODY" | sed "s/'/\\\\'/g")'''[:500]
now = '$NOW'

with open(conv_file) as f:
    conv = json.load(f)

# Find current round
rounds = conv.get('rounds', [])
current_round_idx = conv.get('currentRound', 1) - 1

if current_round_idx < 0 or current_round_idx >= len(rounds):
    # Fallback: use last round
    current_round_idx = len(rounds) - 1 if rounds else -1

if current_round_idx >= 0:
    current_round = rounds[current_round_idx]
    
    # Check if already have response from this agent in this round
    already = any(r.get('from') == from_agent or r.get('agent') == from_agent 
                  for r in current_round.get('responses', []))
    if already:
        print(f'  Already have response from {from_agent} in round {current_round_idx + 1}')
        sys.exit(0)
    
    # Add response to current round
    current_round.setdefault('responses', []).append({
        'from': from_agent,
        'agent': from_agent,
        'ts': now,
        'status': 'received',
        'body': body,
        'summary': body[:200]
    })
    current_round['receivedResponses'] = len(current_round['responses'])
    
    # Check round completion
    expected = current_round.get('expectedResponses', 0)
    received = current_round['receivedResponses']
    if expected and received >= expected:
        current_round['status'] = 'complete'
    elif received > 0:
        current_round['status'] = 'partial'

# Also update top-level for backward compat
top_responses = conv.get('responses', [])
top_already = any(r.get('from') == from_agent or r.get('agent') == from_agent for r in top_responses)
if not top_already:
    top_responses.append({
        'from': from_agent,
        'agent': from_agent,
        'ts': now,
        'status': 'received',
        'summary': body[:200]
    })
    conv['responses'] = top_responses
    conv['receivedResponses'] = len(top_responses)

conv['updatedAt'] = now

# Update top-level status based on current round
if current_round_idx >= 0:
    r_status = rounds[current_round_idx].get('status', 'pending')
    if r_status == 'complete':
        # Check if ALL rounds are complete
        all_complete = all(r.get('status') in ('complete', 'superseded') for r in rounds)
        conv['status'] = 'complete' if all_complete else 'active'
    elif r_status == 'partial':
        conv['status'] = 'active'

with open(conv_file, 'w') as f:
    json.dump(conv, f, indent=2)

round_num = current_round_idx + 1 if current_round_idx >= 0 else '?'
received = current_round.get('receivedResponses', 0) if current_round_idx >= 0 else '?'
expected = current_round.get('expectedResponses', 0) if current_round_idx >= 0 else '?'
print(f'  Updated {conv[\"conversationId\"]}: Round {round_num} - {received}/{expected} ({conv[\"status\"]})')
"

# Log rally/complete to audit if current round just completed
STATUS=$(python3 -c "
import json
with open('$CONV_FILE') as f:
    conv = json.load(f)
rounds = conv.get('rounds', [])
idx = conv.get('currentRound', 1) - 1
if 0 <= idx < len(rounds):
    print(rounds[idx].get('status', 'pending'))
else:
    print('pending')
")

if [[ "$STATUS" == "complete" ]]; then
    AUDIT_LOG="$MESH_HOME/logs/mesh-audit.jsonl"
    ROUND=$(jq -r '.currentRound' "$CONV_FILE")
    RECEIVED=$(python3 -c "import json; c=json.load(open('$CONV_FILE')); r=c['rounds'][c['currentRound']-1]; print(r.get('receivedResponses',0))")
    EXPECTED=$(python3 -c "import json; c=json.load(open('$CONV_FILE')); r=c['rounds'][c['currentRound']-1]; print(r.get('expectedResponses',0))")
    jq -n -c \
        --arg ts "$NOW" \
        --arg conv "$CONV_ID" \
        --argjson received "$RECEIVED" \
        --argjson expected "$EXPECTED" \
        --argjson round "$ROUND" \
        '{ts:$ts, conversationId:$conv, type:"rally/round-complete", status:"complete", round:$round, received:$received, expected:$expected}' \
        >> "$AUDIT_LOG"
    echo "  ✅ Round $ROUND complete ($RECEIVED/$EXPECTED)"
fi
