#!/usr/bin/env bash
# mesh-collab.sh - Multi-agent collaborative session with consensus
#
# Send a question to multiple agents at once, creating a shared session.
# Each agent sees all prior responses. Optionally keeps going until
# agents reach consensus or a round limit is hit.
#
# Usage:
#   # One-shot: fan out to multiple agents, collect responses
#   mesh-collab.sh "How many active tanks?" --agents agent-a,agent-b
#
#   # With a session name
#   mesh-collab.sh "Verify these 52 missing records" --agents agent-a,agent-b --session "data-audit"
#
#   # Multi-round: keep going until consensus (max 3 rounds)
#   mesh-collab.sh "What should we exclude?" --agents agent-a,agent-b --rounds 3
#
#   # With a subject
#   mesh-collab.sh "Check schema drift" --agents agent-a,agent-b,agent-c --subject "Schema audit"

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

if [ -n "${MESH_AGENT:-}" ]; then
    MY_AGENT="$MESH_AGENT"
elif [ -f "$MESH_HOME/config/identity" ]; then
    MY_AGENT="$(cat "$MESH_HOME/config/identity" | tr -d '[:space:]')"
else
    MY_AGENT="${USER:-unknown}"
fi

G='\033[0;32m'; Y='\033[0;33m'; C='\033[0;36m'; R='\033[0;31m'; D='\033[0;90m'; NC='\033[0m'

SESSION_ROUTER="$MESH_HOME/bin/mesh-session-router.sh"

# Parse args
QUESTION=""
AGENTS_STR=""
SESSION_KEY=""
SUBJECT=""
ROUNDS=1
WAIT_SECONDS=30

while [[ $# -gt 0 ]]; do
    case "$1" in
        --agents)     AGENTS_STR="$2"; shift 2 ;;
        --session)    SESSION_KEY="$2"; shift 2 ;;
        --subject)    SUBJECT="$2"; shift 2 ;;
        --rounds)     ROUNDS="$2"; shift 2 ;;
        --wait)       WAIT_SECONDS="$2"; shift 2 ;;
        --help|-h)
            echo "mesh-collab.sh - Multi-agent collaborative session"
            echo ""
            echo "Usage: mesh-collab.sh <question> --agents agent1,agent2 [options]"
            echo ""
            echo "Options:"
            echo "  --agents <a,b,c>     Comma-separated agent list (required)"
            echo "  --session <key>      Session name (auto-generated if omitted)"
            echo "  --subject <text>     Subject line"
            echo "  --rounds <n>         Max consensus rounds (default: 1)"
            echo "  --wait <seconds>     Wait time per agent response (default: 30)"
            exit 0
            ;;
        *)
            if [[ -z "$QUESTION" ]]; then
                QUESTION="$1"
            fi
            shift
            ;;
    esac
done

if [[ -z "$QUESTION" ]]; then
    echo -e "${R}Error: Question required${NC}" >&2
    echo "Usage: mesh-collab.sh <question> --agents agent1,agent2" >&2
    exit 1
fi

if [[ -z "$AGENTS_STR" ]]; then
    echo -e "${R}Error: --agents required${NC}" >&2
    exit 1
fi

IFS=',' read -ra AGENTS <<< "$AGENTS_STR"

# Auto-generate session key if not provided
if [[ -z "$SESSION_KEY" ]]; then
    SESSION_KEY="collab-$(date +%s)-$(openssl rand -hex 3 2>/dev/null || echo $$)"
fi

SUBJECT="${SUBJECT:-Collaborative: ${QUESTION:0:50}}"

echo -e "${C}🐝 MESH Collaborative Session${NC}"
echo -e "  Session:  ${G}${SESSION_KEY}${NC}"
echo -e "  Agents:   ${C}${AGENTS_STR}${NC}"
echo -e "  Rounds:   ${ROUNDS}"
echo -e "  Question: ${QUESTION:0:80}"
echo ""

# Start session
bash "$SESSION_ROUTER" start "$SESSION_KEY" "${AGENTS[@]}" 2>&1 | sed 's/^/  /'

echo ""

for round in $(seq 1 "$ROUNDS"); do
    if [[ $ROUNDS -gt 1 ]]; then
        echo -e "${C}── Round ${round}/${ROUNDS} ──${NC}"
    fi
    
    # Fan out to all agents
    for agent in "${AGENTS[@]}"; do
        echo -e "  ${C}→ Sending to ${agent}...${NC}"
        
        if [[ $round -eq 1 ]]; then
            # First round: send the original question
            bash "$SESSION_ROUTER" send "$SESSION_KEY" "$agent" "$QUESTION" "$SUBJECT (Round $round)" 2>&1 | sed 's/^/    /'
        else
            # Subsequent rounds: ask for consensus based on prior responses
            bash "$SESSION_ROUTER" send "$SESSION_KEY" "$agent" \
                "Review the responses from all agents so far. Do you agree with the consensus? If not, explain your disagreement. If you agree, say CONSENSUS_REACHED." \
                "$SUBJECT (Round $round - consensus check)" 2>&1 | sed 's/^/    /'
        fi
    done
    
    # Wait for responses
    echo ""
    echo -e "  ${D}Waiting ${WAIT_SECONDS}s for responses...${NC}"
    sleep "$WAIT_SECONDS"
    
    # Collect responses from audit logs
    echo ""
    echo -e "  ${G}Responses received:${NC}"
    for agent in "${AGENTS[@]}"; do
        # Check the agent's last reply
        local_audit="$MESH_HOME/logs/mesh-audit.jsonl"
        last_reply=$(tail -20 "$local_audit" 2>/dev/null | \
            jq -r --arg from "$agent" --arg to "$MY_AGENT" \
            'select(.from == $from and .to == $to) | .subject // .body // "no response"' 2>/dev/null | tail -1)
        
        if [[ -n "$last_reply" && "$last_reply" != "no response" ]]; then
            echo -e "    ${G}✓ ${agent}:${NC} ${last_reply:0:120}"
            
            # Record response in session
            local file
            file="$MESH_HOME/sessions/$(echo "$SESSION_KEY" | sed 's/[^a-zA-Z0-9._-]/_/g').json"
            if [[ -f "$file" ]]; then
                tmp=$(mktemp)
                NOW=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
                jq --arg from "$agent" --arg to "$MY_AGENT" --arg body "$last_reply" --arg ts "$NOW" \
                    '.messages += [{from:$from,to:$to,type:"response",subject:"",body:$body,timestamp:$ts}] | .lastActivity = $ts' \
                    "$file" > "$tmp" && mv "$tmp" "$file"
            fi
        else
            echo -e "    ${Y}⏳ ${agent}:${NC} no response yet"
        fi
    done
    
    # Check for consensus in multi-round mode
    if [[ $ROUNDS -gt 1 && $round -gt 1 ]]; then
        consensus_count=0
        for agent in "${AGENTS[@]}"; do
            last_reply=$(tail -20 "$MESH_HOME/logs/mesh-audit.jsonl" 2>/dev/null | \
                jq -r --arg from "$agent" 'select(.from == $from) | .body // ""' 2>/dev/null | tail -1)
            if echo "$last_reply" | grep -qi "CONSENSUS_REACHED"; then
                consensus_count=$((consensus_count + 1))
            fi
        done
        
        if [[ $consensus_count -eq ${#AGENTS[@]} ]]; then
            echo ""
            echo -e "  ${G}✅ CONSENSUS REACHED - all ${#AGENTS[@]} agents agree${NC}"
            break
        elif [[ $round -lt $ROUNDS ]]; then
            echo ""
            echo -e "  ${Y}No consensus yet - continuing to round $((round + 1))${NC}"
        fi
    fi
    
    echo ""
done

# Final summary
echo -e "${C}── Session Summary ──${NC}"
bash "$SESSION_ROUTER" context "$SESSION_KEY" 5

echo ""
echo -e "${D}Full context: mesh-session-router.sh context ${SESSION_KEY}${NC}"
echo -e "${D}Close when done: mesh-session-router.sh close ${SESSION_KEY}${NC}"
