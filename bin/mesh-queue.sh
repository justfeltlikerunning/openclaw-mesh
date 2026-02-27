#!/usr/bin/env bash
# mesh-queue.sh - Persistent message queue with store-and-forward
# Replays dead-lettered messages when agents come back online
#
# Usage:
#   mesh-queue.sh drain              # Retry all dead letters now
#   mesh-queue.sh drain <agent>      # Retry only for specific agent
#   mesh-queue.sh status             # Show queue status
#   mesh-queue.sh purge [agent]      # Purge dead letters (all or per-agent)
#   mesh-queue.sh daemon [interval]  # Run as daemon, check every N seconds (default 60)
#
# Designed to run via cron or as a background daemon.
# Checks agent health before replaying - won't burn retries on dead hosts.

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

REGISTRY="${MESH_REGISTRY:-$MESH_HOME/config/agent-registry.json}"
DEAD_LETTER_FILE="$MESH_HOME/state/dead-letters.json"
QUEUE_LOG="$MESH_HOME/logs/queue-replay.jsonl"
QUEUE_STATE="$MESH_HOME/state/queue-state.json"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Agent identity
if [ -n "${MESH_AGENT:-}" ]; then
    MY_AGENT="$MESH_AGENT"
elif [ -f "$MESH_HOME/config/identity" ]; then
    MY_AGENT="$(cat "$MESH_HOME/config/identity" | tr -d '[:space:]')"
else
    MY_AGENT="${USER:-unknown}"
fi

# Initialize files if missing
[[ -f "$DEAD_LETTER_FILE" ]] || echo '{"messages":[]}' > "$DEAD_LETTER_FILE"
[[ -f "$QUEUE_LOG" ]] || touch "$QUEUE_LOG"
[[ -f "$QUEUE_STATE" ]] || echo '{"lastDrain":null,"totalReplayed":0,"totalPurged":0,"agentStatus":{}}' > "$QUEUE_STATE"

# ── Helper functions ──

get_agent_ip() {
    local agent="$1"
    jq -r ".agents.${agent}.ip" "$REGISTRY"
}

get_agent_port() {
    local agent="$1"
    jq -r ".agents.${agent}.port" "$REGISTRY"
}

get_agent_token() {
    local agent="$1"
    jq -r ".agents.${agent}.token" "$REGISTRY"
}

get_timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%S.000Z"
}

# Check if agent's hook endpoint is alive (quick health ping)
check_agent_health() {
    local agent="$1"
    local ip port
    ip=$(get_agent_ip "$agent")
    port=$(get_agent_port "$agent")
    
    if [[ "$ip" == "null" || -z "$ip" ]]; then
        return 1
    fi
    
    # Quick TCP connect check (1s timeout)
    timeout 2 bash -c "echo >/dev/tcp/${ip}/${port}" 2>/dev/null
    return $?
}

# Log queue replay events
queue_log() {
    local action="$1"
    local agent="$2"
    local msg_id="$3"
    local result="$4"
    local detail="${5:-}"
    local now
    now=$(get_timestamp)
    
    jq -n -c \
        --arg ts "$now" \
        --arg action "$action" \
        --arg agent "$agent" \
        --arg msgId "$msg_id" \
        --arg result "$result" \
        --arg detail "$detail" \
        '{ts:$ts, action:$action, agent:$agent, msgId:$msgId, result:$result, detail:$detail}' >> "$QUEUE_LOG"
}

# Update queue state
update_state() {
    local key="$1"
    local value="$2"
    local tmp
    tmp=$(mktemp)
    jq --arg key "$key" --arg val "$value" '.[$key] = $val' "$QUEUE_STATE" > "$tmp"
    mv "$tmp" "$QUEUE_STATE"
}

# ── Queue status ──

cmd_status() {
    local total pending_agents
    total=$(jq '.messages | length' "$DEAD_LETTER_FILE")
    
    if [[ "$total" -eq 0 ]]; then
        echo -e "${GREEN}Queue empty - no pending messages${NC}"
        return 0
    fi
    
    echo -e "${CYAN}═══ MESH Message Queue Status ═══${NC}"
    echo -e "Total pending: ${YELLOW}${total}${NC}"
    echo ""
    
    # Group by agent
    jq -r '.messages | group_by(.to)[] | "\(.[0].to)|\(length)|\(.[0].failReason)|\(.[0].timestamp)"' "$DEAD_LETTER_FILE" | while IFS='|' read -r agent count reason ts; do
        local health_status
        if check_agent_health "$agent" 2>/dev/null; then
            health_status="${GREEN}● online${NC}"
        else
            health_status="${RED}● offline${NC}"
        fi
        echo -e "  ${agent}: ${YELLOW}${count}${NC} messages | last fail: ${reason} | ${health_status}"
    done
    
    echo ""
    
    # Show last drain
    local last_drain
    last_drain=$(jq -r '.lastDrain // "never"' "$QUEUE_STATE")
    local total_replayed
    total_replayed=$(jq -r '.totalReplayed // 0' "$QUEUE_STATE")
    echo -e "Last drain: ${last_drain}"
    echo -e "Total replayed (lifetime): ${total_replayed}"
}

# ── Drain (replay) dead letters ──

cmd_drain() {
    local filter_agent="${1:-}"
    local total replayed=0 failed=0 skipped=0 expired=0
    
    total=$(jq '.messages | length' "$DEAD_LETTER_FILE")
    
    if [[ "$total" -eq 0 ]]; then
        echo -e "${GREEN}Queue empty - nothing to drain${NC}"
        return 0
    fi
    
    # TTL enforcement - purge expired messages before replay
    local now_epoch
    now_epoch=$(date +%s)
    local pre_ttl_count=$total
    local tmp_ttl
    tmp_ttl=$(mktemp)
    jq --argjson now "$now_epoch" '
        .messages |= [.[] | 
            select(
                (.envelope | if type == "string" then fromjson else . end) as $env |
                (($env.ttl // 300) as $ttl |
                 (($env.timestamp // .timestamp) | sub("\\.[0-9]+Z$"; "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) as $sent |
                 ($now - $sent) < $ttl)
            )
        ]
    ' "$DEAD_LETTER_FILE" > "$tmp_ttl" 2>/dev/null && mv "$tmp_ttl" "$DEAD_LETTER_FILE" || rm -f "$tmp_ttl"
    
    total=$(jq '.messages | length' "$DEAD_LETTER_FILE")
    expired=$((pre_ttl_count - total))
    [[ $expired -gt 0 ]] && echo -e "${YELLOW}⏰ Purged ${expired} expired messages (TTL exceeded)${NC}"
    
    if [[ "$total" -eq 0 ]]; then
        echo -e "${GREEN}Queue empty after TTL cleanup - nothing to drain${NC}"
        return 0
    fi
    
    echo -e "${BLUE}Draining ${total} queued messages...${NC}"
    
    # Get unique agents with pending messages
    local agents
    if [[ -n "$filter_agent" ]]; then
        agents="$filter_agent"
    else
        agents=$(jq -r '.messages[].to' "$DEAD_LETTER_FILE" | sort -u)
    fi
    
    for agent in $agents; do
        # Check health first - don't waste time on dead hosts
        if ! check_agent_health "$agent" 2>/dev/null; then
            local agent_count
            agent_count=$(jq --arg a "$agent" '[.messages[] | select(.to == $a)] | length' "$DEAD_LETTER_FILE")
            echo -e "  ${RED}✗ ${agent} offline - skipping ${agent_count} messages${NC}"
            skipped=$((skipped + agent_count))
            continue
        fi
        
        echo -e "  ${GREEN}● ${agent} online${NC} - replaying messages..."
        
        # Get messages for this agent (oldest first)
        local messages
        messages=$(jq -c --arg a "$agent" '[.messages[] | select(.to == $a)]' "$DEAD_LETTER_FILE")
        local count
        count=$(echo "$messages" | jq 'length')
        
        local i=0
        while [[ $i -lt $count ]]; do
            local msg
            msg=$(echo "$messages" | jq -c ".[$i]")
            local msg_id
            msg_id=$(echo "$msg" | jq -r '.id')
            local envelope
            envelope=$(echo "$msg" | jq -c '.envelope')
            
            # Get connection details
            local ip port token url
            ip=$(get_agent_ip "$agent")
            port=$(get_agent_port "$agent")
            token=$(get_agent_token "$agent")
            
            # Determine URL (same logic as mesh-send.sh)
            local session_key
            session_key=$(echo "$envelope" | jq -r '.replyContext.sessionKey // empty' 2>/dev/null || true)
            if [[ "$session_key" =~ ^agent:[^:]+: ]]; then
                session_key=$(echo "$session_key" | sed 's/^agent:[^:]*://')
            fi
            
            if [[ -n "$session_key" ]]; then
                url="http://${ip}:${port}/hooks/agent"
            else
                url="http://${ip}:${port}/hooks/${MY_AGENT}"
            fi
            
            # Build hook payload
            local hook_payload
            if [[ -n "$session_key" ]]; then
                hook_payload=$(jq -n -c \
                    --arg message "$envelope" \
                    --arg sessionKey "$session_key" \
                    '{message: $message, sessionKey: $sessionKey}')
            else
                hook_payload=$(jq -n -c --arg message "$envelope" '{message: $message}')
            fi
            
            # Add signature header if present
            local sig_header_name="" sig_header_value=""
            local envelope_sig
            envelope_sig=$(echo "$envelope" | jq -r '.signature // ""')
            if [[ -n "$envelope_sig" ]]; then
                sig_header_name="-H"
                sig_header_value="X-MESH-Signature: ${envelope_sig}"
            fi
            
            # Attempt delivery
            local http_code
            http_code=$(curl -s -o /dev/null -w "%{http_code}" \
                --connect-timeout 10 \
                --max-time 30 \
                -X POST "$url" \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer ${token}" \
                ${sig_header_name:+"$sig_header_name" "$sig_header_value"} \
                -d "$hook_payload" 2>/dev/null || echo "000")
            
            if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
                echo -e "    ${GREEN}✓ Replayed ${msg_id} → ${agent} (HTTP ${http_code})${NC}"
                queue_log "replay" "$agent" "$msg_id" "success" "HTTP ${http_code}"
                replayed=$((replayed + 1))
                
                # Remove from dead letters
                local tmp
                tmp=$(mktemp)
                jq --arg id "$msg_id" '.messages |= [.[] | select(.id != $id)]' "$DEAD_LETTER_FILE" > "$tmp"
                mv "$tmp" "$DEAD_LETTER_FILE"
            else
                echo -e "    ${RED}✗ Failed ${msg_id} → ${agent} (HTTP ${http_code}) - keeping in queue${NC}"
                queue_log "replay" "$agent" "$msg_id" "failed" "HTTP ${http_code}"
                failed=$((failed + 1))
            fi
            
            i=$((i + 1))
            
            # Brief pause between messages to avoid hammering
            [[ $i -lt $count ]] && sleep 1
        done
    done
    
    # Update state
    local now
    now=$(get_timestamp)
    local tmp
    tmp=$(mktemp)
    jq --arg ts "$now" --argjson r "$replayed" \
        '.lastDrain = $ts | .totalReplayed = (.totalReplayed + $r)' "$QUEUE_STATE" > "$tmp"
    mv "$tmp" "$QUEUE_STATE"
    
    echo ""
    echo -e "${CYAN}Drain complete:${NC} ${GREEN}${replayed} replayed${NC}, ${RED}${failed} failed${NC}, ${YELLOW}${skipped} skipped (offline)${NC}"
    
    local remaining
    remaining=$(jq '.messages | length' "$DEAD_LETTER_FILE")
    [[ "$remaining" -gt 0 ]] && echo -e "Remaining in queue: ${YELLOW}${remaining}${NC}"
}

# ── Purge ──

cmd_purge() {
    local filter_agent="${1:-}"
    local before_count
    before_count=$(jq '.messages | length' "$DEAD_LETTER_FILE")
    
    if [[ -n "$filter_agent" ]]; then
        local tmp
        tmp=$(mktemp)
        jq --arg a "$filter_agent" '.messages |= [.[] | select(.to != $a)]' "$DEAD_LETTER_FILE" > "$tmp"
        mv "$tmp" "$DEAD_LETTER_FILE"
    else
        echo '{"messages":[]}' > "$DEAD_LETTER_FILE"
    fi
    
    local after_count
    after_count=$(jq '.messages | length' "$DEAD_LETTER_FILE")
    local purged=$((before_count - after_count))
    
    echo -e "${GREEN}Purged ${purged} messages${NC} (${after_count} remaining)"
    queue_log "purge" "${filter_agent:-all}" "-" "success" "purged ${purged}"
}

# ── Daemon mode ──

cmd_daemon() {
    local interval="${1:-60}"
    echo -e "${BLUE}MESH Queue Daemon started - checking every ${interval}s${NC}"
    echo -e "PID: $$"
    
    while true; do
        local total
        total=$(jq '.messages | length' "$DEAD_LETTER_FILE" 2>/dev/null || echo 0)
        
        if [[ "$total" -gt 0 ]]; then
            echo -e "[$(date)] ${YELLOW}${total} queued messages - attempting drain...${NC}"
            cmd_drain 2>&1 | while IFS= read -r line; do
                echo "  $line"
            done
        fi
        
        sleep "$interval"
    done
}

# ── Main ──

ACTION="${1:-status}"

case "$ACTION" in
    status)
        cmd_status
        ;;
    drain)
        cmd_drain "${2:-}"
        ;;
    purge)
        cmd_purge "${2:-}"
        ;;
    daemon)
        cmd_daemon "${2:-60}"
        ;;
    *)
        echo "Usage: mesh-queue.sh {status|drain [agent]|purge [agent]|daemon [interval]}"
        exit 1
        ;;
esac
