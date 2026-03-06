#!/usr/bin/env bash
# mesh-status.sh - Fleet health dashboard in the terminal
# Shows peers, latency, queue, circuits, last messages at a glance.
#
# Usage:
#   mesh-status.sh            # Full dashboard
#   mesh-status.sh --compact  # One-line-per-peer summary
#   mesh-status.sh --json     # Machine-readable JSON

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
    [[ -f "$parent/config/agent-registry.json" ]] && MESH_HOME="$parent" || MESH_HOME="$parent"
fi

REGISTRY="$MESH_HOME/config/agent-registry.json"
PEER_HEALTH="$MESH_HOME/state/peer-health.json"
CIRCUIT_FILE="$MESH_HOME/state/circuit-breakers.json"
DEAD_LETTER="$MESH_HOME/state/dead-letters.json"
ROUTING_TABLE="$MESH_HOME/state/routing-table.json"
AUDIT_LOG="$MESH_HOME/logs/mesh-audit.jsonl"
QUEUE_STATE="$MESH_HOME/state/queue-state.json"

if [ -n "${MESH_AGENT:-}" ]; then
    MY_AGENT="$MESH_AGENT"
elif [ -f "$MESH_HOME/config/identity" ]; then
    MY_AGENT="$(cat "$MESH_HOME/config/identity" | tr -d '[:space:]')"
else
    MY_AGENT="${USER:-unknown}"
fi

# Colors
R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'; B='\033[0;34m'; C='\033[0;36m'; M='\033[0;35m'; W='\033[1;37m'; D='\033[0;90m'; NC='\033[0m'

MODE="${1:-full}"

# ── JSON mode ──
if [[ "$MODE" == "--json" ]]; then
    jq -n \
        --arg agent "$MY_AGENT" \
        --slurpfile peers "$PEER_HEALTH" \
        --slurpfile circuits "$CIRCUIT_FILE" \
        --slurpfile dl "$DEAD_LETTER" \
        --slurpfile rt "$ROUTING_TABLE" \
        --slurpfile qs "$QUEUE_STATE" \
        '{
            agent: $agent,
            peers: $peers[0],
            circuits: $circuits[0],
            deadLetters: ($dl[0].messages | length),
            routingTable: $rt[0],
            queueState: $qs[0]
        }' 2>/dev/null
    exit 0
fi

# ── Gather data ──
total_agents=$(jq -r --arg me "$MY_AGENT" '.agents | keys | map(select(. != $me)) | length' "$REGISTRY" 2>/dev/null || echo 0)
peers_up=$(jq -r '[to_entries[] | select(.value.reachable == true)] | length' "$PEER_HEALTH" 2>/dev/null || echo "?")
peers_down=$((total_agents - peers_up))
queue_count=$(jq '.messages | length' "$DEAD_LETTER" 2>/dev/null || echo 0)
total_messages=$(wc -l < "$AUDIT_LOG" 2>/dev/null || echo 0)
hub=$(jq -r '.hub // "none"' "$ROUTING_TABLE" 2>/dev/null || echo "?")
relay=$(jq -r '.relay // "none"' "$ROUTING_TABLE" 2>/dev/null || echo "none")
total_replayed=$(jq -r '.totalReplayed // 0' "$QUEUE_STATE" 2>/dev/null || echo 0)

# Count signed messages
signed_count=$(grep -c '"signed":true' "$AUDIT_LOG" 2>/dev/null || echo 0)

# Circuit breaker status
open_circuits=$(jq -r '[to_entries[] | select(.value.state == "open")] | length' "$CIRCUIT_FILE" 2>/dev/null || echo 0)

# Last message timestamp
last_msg_ts=$(tail -1 "$AUDIT_LOG" 2>/dev/null | jq -r '.ts // empty' 2>/dev/null || echo "none")

# ── Compact mode ──
if [[ "$MODE" == "--compact" ]]; then
    echo -e "${C}🐝 MESH${NC} ${W}${MY_AGENT}${NC} | Peers: ${G}${peers_up}${NC}/${total_agents} | Queue: ${Y}${queue_count}${NC} | Circuits: $([[ $open_circuits -gt 0 ]] && echo -e "${R}${open_circuits} OPEN${NC}" || echo -e "${G}all closed${NC}") | Hub: ${B}${hub}${NC} | Msgs: ${total_messages}"
    exit 0
fi

# ── Full dashboard ──
echo -e "${C}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${C}║${NC}  ${W}🐝 MESH Fleet Status${NC}  -  ${G}${MY_AGENT}${NC}                      ${C}║${NC}"
echo -e "${C}╚══════════════════════════════════════════════════════╝${NC}"
echo ""

# Overview stats
echo -e "${W}Overview${NC}"
echo -e "  Peers:      ${G}${peers_up}${NC} up / ${R}${peers_down}${NC} down / ${total_agents} total"
echo -e "  Queue:      $([[ $queue_count -gt 0 ]] && echo -e "${Y}${queue_count} pending${NC}" || echo -e "${G}empty${NC}")"
echo -e "  Circuits:   $([[ $open_circuits -gt 0 ]] && echo -e "${R}${open_circuits} OPEN${NC}" || echo -e "${G}all closed${NC}")"
echo -e "  Hub:        ${B}${hub}${NC}  Relay: ${B}${relay}${NC}"
echo -e "  Messages:   ${total_messages} total (${signed_count} signed)"
echo -e "  Replayed:   ${total_replayed} from queue"
echo -e "  Last msg:   ${D}${last_msg_ts}${NC}"
echo ""

# Peer table
echo -e "${W}Peers${NC}"
printf "  ${D}%-14s %-20s %8s %8s %6s %s${NC}\n" "AGENT" "ENDPOINT" "LATENCY" "STATUS" "FAILS" "CIRCUIT"

jq -r --arg me "$MY_AGENT" '
    .agents | to_entries[] | select(.key != $me) | "\(.key)|\(.value.ip):\(.value.port)"
' "$REGISTRY" 2>/dev/null | while IFS='|' read -r agent endpoint; do
    [[ -z "$agent" ]] && continue
    
    # Peer health
    reachable=$(jq -r --arg a "$agent" '.[$a].reachable // "?"' "$PEER_HEALTH" 2>/dev/null)
    latency=$(jq -r --arg a "$agent" '.[$a].latencyMs // "?"' "$PEER_HEALTH" 2>/dev/null)
    failures=$(jq -r --arg a "$agent" '.[$a].consecutiveFailures // 0' "$PEER_HEALTH" 2>/dev/null)
    
    # Circuit state
    circuit=$(jq -r --arg a "$agent" '.[$a].state // "closed"' "$CIRCUIT_FILE" 2>/dev/null)
    
    # Format
    if [[ "$reachable" == "true" ]]; then
        status="${G}● online ${NC}"
        lat_fmt="${G}${latency}ms${NC}"
    elif [[ "$reachable" == "false" ]]; then
        status="${R}● offline${NC}"
        lat_fmt="${R}-${NC}"
    else
        status="${D}? unknown${NC}"
        lat_fmt="${D}-${NC}"
    fi
    
    if [[ "$circuit" == "open" ]]; then
        circ_fmt="${R}OPEN${NC}"
    elif [[ "$circuit" == "half-open" ]]; then
        circ_fmt="${Y}HALF${NC}"
    else
        circ_fmt="${G}closed${NC}"
    fi
    
    printf "  %-14s %-20s %b %b %6s %b\n" "$agent" "$endpoint" "$lat_fmt" "$status" "$failures" "$circ_fmt"
done

echo ""

# Queue details (if any)
if [[ $queue_count -gt 0 ]]; then
    echo -e "${W}Queue${NC} (${Y}${queue_count} pending${NC})"
    jq -r '.messages[] | "  \(.to) - \(.failReason) - \(.timestamp)"' "$DEAD_LETTER" 2>/dev/null | head -5
    [[ $queue_count -gt 5 ]] && echo -e "  ${D}... and $((queue_count - 5)) more${NC}"
    echo ""
fi

# Recent messages
echo -e "${W}Recent Messages${NC} (last 5)"
tail -5 "$AUDIT_LOG" 2>/dev/null | while IFS= read -r line; do
    from=$(echo "$line" | jq -r '.from // "?"')
    to=$(echo "$line" | jq -r '.to // "?"')
    type=$(echo "$line" | jq -r '.type // "?"')
    status=$(echo "$line" | jq -r '.status // "?"')
    ts=$(echo "$line" | jq -r '.ts // ""' | sed 's/T/ /' | sed 's/\.000Z//')
    signed=$(echo "$line" | jq -r '.signed // false')
    subj=$(echo "$line" | jq -r '.subject // ""' | head -c 40)
    
    sign_icon=$([[ "$signed" == "true" ]] && echo "🔐" || echo "  ")
    status_icon=$([[ "$status" == "sent" ]] && echo -e "${G}✓${NC}" || echo -e "${R}✗${NC}")
    
    printf "  ${D}%s${NC} %s ${sign_icon} ${from} → ${to} [${type}] ${subj} %b\n" "$ts" "$status_icon" ""
done

echo ""
echo -e "${D}Run 'mesh-discover.sh probe' to refresh peer data${NC}"
