#!/usr/bin/env bash
# mesh-consensus.sh - MESH v3 Consensus Detection
# Analyzes conversation responses to detect agreement or disagreement.
#
# Usage: mesh-consensus.sh <conv_id> [--round N]
# Output: JSON with consensus result

set -euo pipefail

MESH_HOME="${MESH_HOME:-$HOME/clawd/openclaw-mesh}"
CONV_DIR="$MESH_HOME/state/conversations"

CONV_ID="${1:-}"
ROUND_NUM="${3:-}"
shift || true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --round) ROUND_NUM="$2"; shift 2 ;;
        *) shift ;;
    esac
done

[[ -z "$CONV_ID" ]] && { echo '{"error":"Usage: mesh-consensus.sh <conv_id> [--round N]"}'; exit 1; }

CONV_FILE="$CONV_DIR/${CONV_ID}.json"
[[ -f "$CONV_FILE" ]] || { echo '{"error":"Conversation not found"}'; exit 1; }

export CONV_ID CONV_FILE ROUND_NUM

python3 <<'PYEOF'
import json, re, sys, os

conv_id = os.environ['CONV_ID']
conv_file = os.environ['CONV_FILE']
round_num = os.environ.get('ROUND_NUM', '')

with open(conv_file) as f:
    conv = json.load(f)

rounds = conv.get('rounds', [])
target_round = None

if not rounds:
    responses = conv.get('responses', [])
    if not responses:
        print(json.dumps({"conversationId": conv_id, "consensus": "no_data", "detail": "No responses found"}))
        sys.exit(0)
    target_responses = responses
else:
    if round_num:
        rn = int(round_num)
        target_round = next((r for r in rounds if r.get('round') == rn), None)
    else:
        completed = [r for r in rounds if r.get('status') in ('complete', 'superseded')]
        target_round = completed[-1] if completed else rounds[-1]
    
    if not target_round:
        print(json.dumps({"conversationId": conv_id, "consensus": "no_data", "detail": "Round not found"}))
        sys.exit(0)
    target_responses = target_round.get('responses', [])

if len(target_responses) < 2:
    print(json.dumps({"conversationId": conv_id, "consensus": "insufficient", "detail": f"Only {len(target_responses)} response(s)"}))
    sys.exit(0)

def extract_value(body):
    text = body.strip()
    for prefix in ['Response:', 'Responded with:', 'Answer:', 'Result:']:
        if text.lower().startswith(prefix.lower()):
            text = text[len(prefix):].strip()
    numbers = re.findall(r'[\d,]+\.?\d*', text)
    if numbers:
        try:
            return float(numbers[0].replace(',', ''))
        except ValueError:
            pass
    return text.lower().strip()

values = {}
raw_values = {}
for resp in target_responses:
    agent = resp.get('agent', resp.get('from', '?'))
    body = resp.get('body', resp.get('summary', ''))
    val = extract_value(body)
    values[agent] = val
    raw_values[agent] = body.strip()[:200]

unique_vals = set()
for v in values.values():
    if isinstance(v, float):
        unique_vals.add(round(v, 2))
    else:
        unique_vals.add(v)

agents = list(values.keys())
result = {
    "conversationId": conv_id,
    "round": target_round.get('round', '?') if target_round else None,
    "agents": agents,
    "values": {a: str(v) for a, v in values.items()},
    "rawResponses": raw_values,
}

if len(unique_vals) == 1:
    result["consensus"] = "match"
    result["consensusValue"] = str(list(unique_vals)[0])
    result["detail"] = f"All {len(agents)} agents agree: {list(unique_vals)[0]}"
    result["discrepancy"] = 0.0
elif all(isinstance(v, float) for v in values.values()):
    vals = list(values.values())
    min_v, max_v = min(vals), max(vals)
    avg = sum(vals) / len(vals)
    pct_diff = ((max_v - min_v) / avg * 100) if avg > 0 else (0 if min_v == max_v else 100)
    
    if pct_diff <= 1.0:
        result["consensus"] = "near_match"
        result["detail"] = f"Within 1%: {', '.join(f'{a}={v}' for a,v in values.items())}"
    elif pct_diff <= 5.0:
        result["consensus"] = "close"
        result["detail"] = f"Within 5%: {', '.join(f'{a}={v}' for a,v in values.items())}"
    else:
        result["consensus"] = "disagree"
        result["detail"] = f"Differ by {pct_diff:.1f}%: {', '.join(f'{a}={v}' for a,v in values.items())}"
    result["discrepancy"] = round(pct_diff, 2)
else:
    vals = list(values.values())
    if all(v == vals[0] for v in vals):
        result["consensus"] = "match"
        result["detail"] = "All agents agree"
        result["discrepancy"] = 0
    else:
        result["consensus"] = "disagree"
        parts = [a + '="' + str(v)[:50] + '"' for a,v in values.items()]
        result["detail"] = "Responses differ: " + ", ".join(parts)
        result["discrepancy"] = None

print(json.dumps(result, indent=2))
PYEOF
