#!/usr/bin/env bash
# mesh-converse.sh - MESH v3 Conversation Initiator (supports all conversation types)
# Allows any agent to start conversations: collab, escalation, broadcast, rally
#
# Usage: mesh-converse.sh <type> "<message>" [options]
#
# Types:
#   rally        - One question to N agents, collect responses (same as mesh-rally.sh)
#   collab       - Multi-turn discussion between agents (each sees all context)
#   escalation   - Issue flows up trust hierarchy
#   broadcast    - One-way notification to subset/all (no responses expected)
#   broadcast --ack - Broadcast that expects acknowledgment from each agent
#   opinion      - Request opinions/perspectives from agents (response expected, no consensus)
#   brainstorm   - Open-ended ideation session (all ideas welcome, multi-turn)
#
# Options:
#   --agents <list>     Comma-separated agent names
#   --ttl <seconds>     Time-to-live (default: 300, broadcast: 60)
#   --priority <level>  high|normal|low
#   --conv-id <id>      Continue existing conversation
#   --subject <text>    Subject line
#   --file <path>       Attach file
#   --ack               (broadcast only) Expect acknowledgment from each agent
#
# Examples:
#   mesh-converse.sh collab "Let's investigate the schema mismatch" --agents "agent-a,agent-b"
#   mesh-converse.sh escalation "Dashboard down after deploy" --agents "agent-d,agent-e,coordinator"
#   mesh-converse.sh broadcast "Schema v3 deployed" --agents "all"
#   mesh-converse.sh broadcast "New policy: all MESH responses must include conv-id" --agents "all" --ack
#   mesh-converse.sh opinion "Should we migrate to HTTP-based audit collection?" --agents "agent-a,agent-b,agent-f"
#   mesh-converse.sh brainstorm "What new cross-checks should we add?" --agents "agent-a,agent-b"

set -euo pipefail

if [ -n "${BASH_SOURCE[0]:-}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
elif [ -n "${0:-}" ] && [ "$0" != "bash" ] && [ "$0" != "-bash" ] && [ "$0" != "sh" ]; then
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
else
    SCRIPT_DIR="$HOME/clawd/scripts"
fi

MESH_HOME="${MESH_HOME:-$HOME/clawd/openclaw-mesh}"
if [ -n "${MESH_AGENT:-}" ]; then
    MY_AGENT="$MESH_AGENT"
elif [ -f "$MESH_HOME/config/identity" ]; then
    MY_AGENT="$(cat "$MESH_HOME/config/identity" | tr -d '[:space:]')"
else
    MY_AGENT="${USER:-unknown}"
fi

CONV_TYPE="${1:-rally}"
MESSAGE="${2:-}"
shift 2 || true

AGENTS="all"
TTL=""
PRIORITY="normal"
CONV_ID=""
SUBJECT=""
FILE_ARG=""
ACK=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --agents)   AGENTS="$2"; shift 2 ;;
        --ttl)      TTL="$2"; shift 2 ;;
        --priority) PRIORITY="$2"; shift 2 ;;
        --conv-id)  CONV_ID="$2"; shift 2 ;;
        --subject)  SUBJECT="$2"; shift 2 ;;
        --file)     FILE_ARG="--file $2"; shift 2 ;;
        --ack)      ACK=true; shift ;;
        *) shift ;;
    esac
done

[[ -z "$MESSAGE" ]] && { echo "Usage: mesh-converse.sh <type> \"<message>\" [options]"; exit 1; }

case "$CONV_TYPE" in
    rally)
        # Delegate to mesh-rally.sh
        EXTRA=""
        [[ -n "$CONV_ID" ]] && EXTRA="--conv-id $CONV_ID"
        [[ -n "$SUBJECT" ]] && EXTRA="$EXTRA --subject \"$SUBJECT\""
        [[ -n "$TTL" ]] && EXTRA="$EXTRA --ttl $TTL"
        eval bash "$SCRIPT_DIR/mesh-rally.sh" \"\$MESSAGE\" --agents "$AGENTS" --priority "$PRIORITY" $FILE_ARG $EXTRA
        ;;
    
    collab)
        # Collaborative discussion - same as rally but with different type label
        # Key difference: collab expects multi-turn by default, and includes
        # "This is a collaborative discussion" preamble
        [[ -z "$TTL" ]] && TTL=600
        EXTRA=""
        [[ -n "$CONV_ID" ]] && EXTRA="--conv-id $CONV_ID"
        
        COLLAB_MSG="[COLLAB] $MESSAGE

This is a collaborative discussion. Share your analysis, findings, or perspective. Your response will be shared with all other participants in subsequent rounds."
        
        eval bash "$SCRIPT_DIR/mesh-rally.sh" \"\$COLLAB_MSG\" --agents "$AGENTS" --ttl "$TTL" --priority "$PRIORITY" $FILE_ARG $EXTRA
        
        # Tag conversation as collab type
        if [[ -z "$CONV_ID" ]]; then
            # Find the most recent conv file
            LATEST=$(ls -t "$MESH_HOME/state/conversations/"conv_*.json 2>/dev/null | head -1)
            if [[ -n "$LATEST" ]]; then
                jq '.type = "collab"' "$LATEST" > "${LATEST}.tmp" && mv "${LATEST}.tmp" "$LATEST"
            fi
        else
            CONV_FILE="$MESH_HOME/state/conversations/${CONV_ID}.json"
            [[ -f "$CONV_FILE" ]] && { jq '.type = "collab"' "$CONV_FILE" > "${CONV_FILE}.tmp" && mv "${CONV_FILE}.tmp" "$CONV_FILE"; }
        fi
        ;;
    
    escalation)
        # Escalation - messages agents in order (trust hierarchy)
        # First agent gets the raw message, subsequent agents get prior context
        [[ -z "$TTL" ]] && TTL=600
        
        if [[ "$AGENTS" == "all" ]]; then
            echo "ERROR: Escalation requires specific agents in order (e.g., --agents agent-d,agent-e,coordinator)" >&2
            exit 1
        fi
        
        CONV_ID="conv_$(date +%s)_$(head -c 4 /dev/urandom | xxd -p)"
        CONV_DIR="$MESH_HOME/state/conversations"
        mkdir -p "$CONV_DIR"
        CONV_FILE="$CONV_DIR/${CONV_ID}.json"
        NOW="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
        
        AGENT_LIST=$(echo "$AGENTS" | tr ',' '\n')
        AGENT_COUNT=$(echo "$AGENT_LIST" | grep -c .)
        
        # Create conversation state
        jq -n \
            --arg id "$CONV_ID" \
            --arg from "$MY_AGENT" \
            --arg question "$MESSAGE" \
            --arg participants "$AGENTS" \
            --argjson expected "$AGENT_COUNT" \
            --arg ts "$NOW" \
            --argjson ttl "$TTL" \
            '{
                conversationId: $id,
                type: "escalation",
                from: $from,
                question: $question,
                participants: ($participants | split(",")),
                expectedResponses: $expected,
                receivedResponses: 0,
                responses: [],
                rounds: [{round:1, question:$question, ts:$ts, responses:[], status:"pending", expectedResponses:$expected, receivedResponses:0}],
                currentRound: 1,
                escalationChain: ($participants | split(",")),
                status: "active",
                createdAt: $ts,
                updatedAt: $ts,
                ttl: $ttl
            }' > "$CONV_FILE"
        
        echo "🔺 Escalation [${CONV_ID}]"
        echo "   Chain: $AGENTS"
        echo "   Issue: $(echo "$MESSAGE" | head -c 80)"
        echo "---"
        
        # Send to all agents in the chain simultaneously (they each see the escalation context)
        ESC_MSG="[ESCALATION] $MESSAGE

⚠️ This is an escalation. Escalation chain: $AGENTS
Your role: Investigate and respond. If you cannot resolve, the next agent in the chain will be engaged.
Respond via MESH with your findings."
        
        for agent in $AGENT_LIST; do
            bash "$SCRIPT_DIR/mesh-send.sh" "$agent" request "$ESC_MSG" \
                --conversation-id "$CONV_ID" \
                --subject "[ESC] $(echo "$MESSAGE" | head -c 60)" \
                --ttl "$TTL" \
                --priority "high" \
                --no-retry $FILE_ARG 2>&1
        done
        
        echo "---"
        echo "🔺 Escalation sent to $AGENT_COUNT agents"
        ;;
    
    broadcast)
        # Broadcast - notification with optional ack
        [[ -z "$TTL" ]] && TTL=120
        
        CONV_ID="conv_$(date +%s)_$(head -c 4 /dev/urandom | xxd -p)"
        CONV_DIR="$MESH_HOME/state/conversations"
        mkdir -p "$CONV_DIR"
        NOW="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
        
        # Build target list
        if [[ "$AGENTS" == "all" ]]; then
            TARGETS=$(jq -r --arg me "$MY_AGENT" '.agents | keys[] | select(. != $me)' "$MESH_HOME/config/agent-registry.json")
        else
            TARGETS=$(echo "$AGENTS" | tr ',' '\n')
        fi
        TARGET_LIST=$(echo "$TARGETS" | tr '\n' ',' | sed 's/,$//')
        TARGET_COUNT=$(echo "$TARGETS" | grep -c .)
        
        # With --ack: expect responses; without: fire-and-forget
        EXPECTED=0
        STATUS="complete"
        MSG_TYPE="notification"
        PREAMBLE="[BROADCAST] "
        if [[ "$ACK" == true ]]; then
            EXPECTED=$TARGET_COUNT
            STATUS="active"
            MSG_TYPE="request"
            PREAMBLE="[BROADCAST - ACK REQUIRED] "
        fi
        
        # Create conversation state
        jq -n \
            --arg id "$CONV_ID" \
            --arg from "$MY_AGENT" \
            --arg question "$MESSAGE" \
            --arg participants "$TARGET_LIST" \
            --argjson expected "$EXPECTED" \
            --arg status "$STATUS" \
            --arg ts "$NOW" \
            --argjson ttl "$TTL" \
            --argjson ack "$ACK" \
            '{
                conversationId: $id,
                type: "broadcast",
                from: $from,
                question: $question,
                participants: ($participants | split(",")),
                expectedResponses: $expected,
                receivedResponses: 0,
                rounds: (if $ack then [{round:1, question:$question, ts:$ts, responses:[], status:"pending", expectedResponses:$expected, receivedResponses:0}] else [] end),
                status: $status,
                ackRequired: $ack,
                createdAt: $ts,
                updatedAt: $ts,
                ttl: $ttl
            }' > "$CONV_DIR/${CONV_ID}.json"
        
        # Auto-complete if no ack needed
        if [[ "$ACK" != true ]]; then
            jq --arg ts "$NOW" '.completedAt = $ts' "$CONV_DIR/${CONV_ID}.json" > "$CONV_DIR/${CONV_ID}.json.tmp" && mv "$CONV_DIR/${CONV_ID}.json.tmp" "$CONV_DIR/${CONV_ID}.json"
        fi
        
        local_icon="📢"
        [[ "$ACK" == true ]] && local_icon="📢✋"
        echo "$local_icon Broadcast [${CONV_ID}]"
        echo "   To: $TARGET_LIST ($TARGET_COUNT agents)"
        [[ "$ACK" == true ]] && echo "   ⚡ Acknowledgment required"
        echo "   Msg: $(echo "$MESSAGE" | head -c 80)"
        echo "---"
        
        SENT=0
        ACK_SUFFIX=""
        [[ "$ACK" == true ]] && ACK_SUFFIX="

Reply with a brief acknowledgment (e.g., 'Acknowledged' or 'Received') via MESH response."
        
        for agent in $TARGETS; do
            bash "$SCRIPT_DIR/mesh-send.sh" "$agent" "$MSG_TYPE" "${PREAMBLE}${MESSAGE}${ACK_SUFFIX}" \
                --conversation-id "$CONV_ID" \
                --subject "[BROADCAST] $(echo "$MESSAGE" | head -c 60)" \
                --ttl "$TTL" \
                --no-retry $FILE_ARG 2>&1 && SENT=$((SENT + 1))
        done
        
        echo "---"
        echo "$local_icon Broadcast complete: ${SENT}/${TARGET_COUNT} delivered"
        ;;
    
    opinion)
        # Opinion - request perspectives from agents (response expected, subjective)
        [[ -z "$TTL" ]] && TTL=600
        EXTRA=""
        [[ -n "$CONV_ID" ]] && EXTRA="--conv-id $CONV_ID"
        
        OPINION_MSG="[OPINION REQUESTED] $MESSAGE

Share your perspective or recommendation based on your domain expertise. There's no single right answer - we want diverse viewpoints. Reply via MESH."
        
        eval bash "$SCRIPT_DIR/mesh-rally.sh" \"\$OPINION_MSG\" --agents "$AGENTS" --ttl "$TTL" --priority "$PRIORITY" $FILE_ARG $EXTRA
        
        # Tag conversation type
        if [[ -z "$CONV_ID" ]]; then
            LATEST=$(ls -t "$MESH_HOME/state/conversations/"conv_*.json 2>/dev/null | head -1)
            [[ -n "$LATEST" ]] && { jq '.type = "opinion"' "$LATEST" > "${LATEST}.tmp" && mv "${LATEST}.tmp" "$LATEST"; }
        else
            CONV_FILE="$MESH_HOME/state/conversations/${CONV_ID}.json"
            [[ -f "$CONV_FILE" ]] && { jq '.type = "opinion"' "$CONV_FILE" > "${CONV_FILE}.tmp" && mv "${CONV_FILE}.tmp" "$CONV_FILE"; }
        fi
        ;;
    
    brainstorm)
        # Brainstorm - open-ended ideation, multi-turn encouraged
        [[ -z "$TTL" ]] && TTL=900
        EXTRA=""
        [[ -n "$CONV_ID" ]] && EXTRA="--conv-id $CONV_ID"
        
        BRAIN_MSG="[BRAINSTORM] $MESSAGE

This is an open brainstorming session. Share any ideas, wild or practical. Think creatively - no idea is too out there. All suggestions will be shared with other participants in follow-up rounds. Reply via MESH."
        
        eval bash "$SCRIPT_DIR/mesh-rally.sh" \"\$BRAIN_MSG\" --agents "$AGENTS" --ttl "$TTL" --priority "$PRIORITY" $FILE_ARG $EXTRA
        
        # Tag conversation type
        if [[ -z "$CONV_ID" ]]; then
            LATEST=$(ls -t "$MESH_HOME/state/conversations/"conv_*.json 2>/dev/null | head -1)
            [[ -n "$LATEST" ]] && { jq '.type = "brainstorm"' "$LATEST" > "${LATEST}.tmp" && mv "${LATEST}.tmp" "$LATEST"; }
        else
            CONV_FILE="$MESH_HOME/state/conversations/${CONV_ID}.json"
            [[ -f "$CONV_FILE" ]] && { jq '.type = "brainstorm"' "$CONV_FILE" > "${CONV_FILE}.tmp" && mv "${CONV_FILE}.tmp" "$CONV_FILE"; }
        fi
        ;;
    
    *)
        echo "Unknown conversation type: $CONV_TYPE"
        echo "Types: rally, collab, escalation, broadcast, opinion, brainstorm"
        exit 1
        ;;
esac
