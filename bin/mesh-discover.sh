#!/usr/bin/env bash
# mesh-discover.sh - Peer discovery and health for true mesh networking
# Probes all known peers, builds routing table, detects hub failover
#
# Usage:
#   mesh-discover.sh probe              # Probe all peers, update routing table
#   mesh-discover.sh status             # Show current peer health
#   mesh-discover.sh routes             # Show routing table
#   mesh-discover.sh elect              # Run relay election (who takes over if hub dies)
#   mesh-discover.sh join <ip> <port> <token>  # Join an existing mesh network
#   mesh-discover.sh gossip             # Share routing table with peers
#
# Designed to run periodically (cron/timer) for continuous mesh awareness.

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
ROUTING_TABLE="$MESH_HOME/state/routing-table.json"
PEER_HEALTH="$MESH_HOME/state/peer-health.json"
DISCOVER_LOG="$MESH_HOME/logs/discover.jsonl"

# Agent identity
if [ -n "${MESH_AGENT:-}" ]; then
    MY_AGENT="$MESH_AGENT"
elif [ -f "$MESH_HOME/config/identity" ]; then
    MY_AGENT="$(cat "$MESH_HOME/config/identity" | tr -d '[:space:]')"
else
    MY_AGENT="${USER:-unknown}"
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

get_timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%S.000Z"
}

# Initialize state files
init_state() {
    [[ -f "$PEER_HEALTH" ]] || echo '{}' > "$PEER_HEALTH"
    [[ -f "$ROUTING_TABLE" ]] || jq -n '{
        version: 1,
        lastUpdated: null,
        self: $agent,
        hub: null,
        relay: null,
        peers: {},
        routes: {}
    }' --arg agent "$MY_AGENT" > "$ROUTING_TABLE"
    [[ -f "$DISCOVER_LOG" ]] || touch "$DISCOVER_LOG"
}

# ── Probe a single peer ──
# Uses lightweight /api/status or TCP check - does NOT post to /hooks/
# to avoid waking agent AI sessions and burning tokens
probe_peer() {
    local agent="$1"
    local ip="$2"
    local port="$3"
    local token="$4"
    
    local start_ms=$(date +%s%N)
    local http_code
    
    # Lightweight health probe - does NOT post to /hooks/ (which wakes agent AI sessions)
    # Try GET /api/status first (no auth needed, no session wake), fall back to TCP connect
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 3 \
        --max-time 5 \
        "http://${ip}:${port}/api/status" \
        2>/dev/null || echo "000")
    
    # If /api/status doesn't exist (404/405), try a simple TCP probe
    if [[ "$http_code" == "404" || "$http_code" == "405" ]]; then
        # TCP-only check: can we connect at all?
        if timeout 3 bash -c "echo > /dev/tcp/${ip}/${port}" 2>/dev/null; then
            http_code="200"
        else
            http_code="000"
        fi
    fi
    
    local end_ms=$(date +%s%N)
    local latency_ms=$(( (end_ms - start_ms) / 1000000 ))
    
    local reachable=false
    [[ "$http_code" =~ ^2[0-9][0-9]$ ]] && reachable=true
    
    # Update peer health
    local tmp=$(mktemp)
    local now=$(get_timestamp)
    jq --arg a "$agent" --arg ip "$ip" --argjson port "$port" \
       --arg code "$http_code" --argjson latency "$latency_ms" \
       --argjson reachable "$reachable" --arg ts "$now" \
       '.[$a] = {ip:$ip, port:$port, lastProbe:$ts, httpCode:$code, latencyMs:$latency, reachable:$reachable, consecutiveFailures:(if $reachable then 0 else ((.[$a].consecutiveFailures // 0) + 1) end)}' \
       "$PEER_HEALTH" > "$tmp"
    mv "$tmp" "$PEER_HEALTH"
    
    echo "$reachable|$http_code|$latency_ms"
}

# ── Probe all peers ──
cmd_probe() {
    init_state
    local now=$(get_timestamp)
    
    echo -e "${CYAN}Probing mesh peers...${NC}"
    
    local agents
    agents=$(jq -r --arg me "$MY_AGENT" '.agents | to_entries[] | select(.key != $me) | "\(.key)|\(.value.ip)|\(.value.port)|\(.value.token)"' "$REGISTRY")
    
    local total=0 up=0 down=0
    
    while IFS='|' read -r agent ip port token; do
        [[ -z "$agent" ]] && continue
        total=$((total + 1))
        
        local result
        result=$(probe_peer "$agent" "$ip" "$port" "$token")
        
        local reachable=$(echo "$result" | cut -d'|' -f1)
        local code=$(echo "$result" | cut -d'|' -f2)
        local latency=$(echo "$result" | cut -d'|' -f3)
        
        if [[ "$reachable" == "true" ]]; then
            up=$((up + 1))
            echo -e "  ${GREEN}●${NC} ${agent} (${ip}:${port}) - ${latency}ms"
        else
            down=$((down + 1))
            echo -e "  ${RED}●${NC} ${agent} (${ip}:${port}) - HTTP ${code}"
        fi
    done <<< "$agents"
    
    # Update routing table
    local tmp=$(mktemp)
    jq --arg ts "$now" --argjson up "$up" --argjson down "$down" --argjson total "$total" \
       '.lastUpdated = $ts | .meshHealth = {up:$up, down:$down, total:$total}' \
       "$ROUTING_TABLE" > "$tmp"
    mv "$tmp" "$ROUTING_TABLE"
    
    echo ""
    echo -e "${CYAN}Mesh health:${NC} ${GREEN}${up}/${total} peers reachable${NC}"
    [[ $down -gt 0 ]] && echo -e "${YELLOW}${down} peers unreachable${NC}"
    
    # Log
    jq -n -c --arg ts "$now" --arg agent "$MY_AGENT" --argjson up "$up" --argjson down "$down" \
       '{ts:$ts, action:"probe", agent:$agent, peersUp:$up, peersDown:$down}' >> "$DISCOVER_LOG"
}

# ── Show peer health status ──
cmd_status() {
    init_state
    
    if [[ ! -s "$PEER_HEALTH" ]] || [[ "$(cat "$PEER_HEALTH")" == "{}" ]]; then
        echo -e "${YELLOW}No peer data - run 'mesh-discover.sh probe' first${NC}"
        return 0
    fi
    
    echo -e "${CYAN}═══ Mesh Peer Health ═══${NC}"
    echo -e "Self: ${GREEN}${MY_AGENT}${NC}"
    echo ""
    
    jq -r 'to_entries[] | "\(.key)|\(.value.reachable)|\(.value.latencyMs)|\(.value.lastProbe)|\(.value.consecutiveFailures)|\(.value.ip):\(.value.port)"' "$PEER_HEALTH" | \
    while IFS='|' read -r agent reachable latency last_probe failures endpoint; do
        if [[ "$reachable" == "true" ]]; then
            echo -e "  ${GREEN}●${NC} ${agent} (${endpoint}) - ${latency}ms - last: ${last_probe}"
        else
            echo -e "  ${RED}●${NC} ${agent} (${endpoint}) - ${failures} consecutive failures - last: ${last_probe}"
        fi
    done
}

# ── Show routing table ──
cmd_routes() {
    init_state
    
    echo -e "${CYAN}═══ Mesh Routing Table ═══${NC}"
    echo -e "Self: ${GREEN}${MY_AGENT}${NC}"
    
    local hub relay
    hub=$(jq -r '.hub // "none"' "$ROUTING_TABLE")
    relay=$(jq -r '.relay // "none"' "$ROUTING_TABLE")
    echo -e "Hub: ${BLUE}${hub}${NC}"
    echo -e "Relay: ${BLUE}${relay}${NC}"
    echo ""
    
    # Show direct routes
    echo "Direct routes:"
    jq -r --arg me "$MY_AGENT" '.agents | to_entries[] | select(.key != $me) | "  \(.key) → \(.value.ip):\(.value.port)"' "$REGISTRY"
}

# ── Relay election ──
# When hub is unreachable, elect a relay from available peers
# Priority: explicit relay > lowest latency > alphabetical
cmd_elect() {
    init_state
    
    # Get hub identity
    local hub
    hub=$(jq -r '.hub // empty' "$ROUTING_TABLE")
    
    if [[ -z "$hub" ]]; then
        # Determine hub: agent with role "hub" in registry, or first agent
        hub=$(jq -r '.agents | to_entries[] | select(.value.role == "hub") | .key' "$REGISTRY" | head -1)
        [[ -z "$hub" ]] && hub=$(jq -r '.agents | keys[0]' "$REGISTRY")
    fi
    
    echo -e "${CYAN}Hub: ${hub}${NC}"
    
    # Check if hub is reachable
    local hub_reachable
    hub_reachable=$(jq -r --arg h "$hub" '.[$h].reachable // false' "$PEER_HEALTH")
    
    if [[ "$hub_reachable" == "true" || "$hub" == "$MY_AGENT" ]]; then
        echo -e "${GREEN}Hub is reachable - no election needed${NC}"
        
        # Update routing table
        local tmp=$(mktemp)
        jq --arg h "$hub" '.hub = $h | .relay = null' "$ROUTING_TABLE" > "$tmp"
        mv "$tmp" "$ROUTING_TABLE"
        return 0
    fi
    
    echo -e "${RED}Hub is UNREACHABLE - electing relay...${NC}"
    
    # Find best relay candidate:
    # 1. Agent with role "relay" or "sre"
    # 2. Lowest latency reachable peer
    # 3. Alphabetical fallback
    
    local relay_candidate=""
    
    # Priority 1: explicit relay role
    relay_candidate=$(jq -r '.agents | to_entries[] | select(.value.role == "relay" or .value.role == "sre") | .key' "$REGISTRY" | head -1)
    
    # Verify it's reachable
    if [[ -n "$relay_candidate" ]]; then
        local rc_reachable
        rc_reachable=$(jq -r --arg r "$relay_candidate" '.[$r].reachable // false' "$PEER_HEALTH")
        [[ "$rc_reachable" != "true" ]] && relay_candidate=""
    fi
    
    # Priority 2: lowest latency reachable peer
    if [[ -z "$relay_candidate" ]]; then
        relay_candidate=$(jq -r 'to_entries | map(select(.value.reachable == true)) | sort_by(.value.latencyMs) | .[0].key // empty' "$PEER_HEALTH")
    fi
    
    if [[ -z "$relay_candidate" ]]; then
        echo -e "${RED}No reachable peers - mesh is isolated${NC}"
        return 1
    fi
    
    echo -e "${GREEN}Elected relay: ${relay_candidate}${NC}"
    
    # Update routing table
    local now=$(get_timestamp)
    local tmp=$(mktemp)
    jq --arg h "$hub" --arg r "$relay_candidate" --arg ts "$now" \
       '.hub = $h | .relay = $r | .lastElection = $ts' "$ROUTING_TABLE" > "$tmp"
    mv "$tmp" "$ROUTING_TABLE"
    
    # Log election
    jq -n -c --arg ts "$now" --arg agent "$MY_AGENT" --arg relay "$relay_candidate" --arg hub "$hub" \
       '{ts:$ts, action:"election", agent:$agent, hub:$hub, relay:$relay, reason:"hub_unreachable"}' >> "$DISCOVER_LOG"
    
    echo -e "Routing table updated. Messages to hub will route via ${relay_candidate}."
}

# ── Join mesh ──
cmd_join() {
    local peer_ip="$1"
    local peer_port="${2:-18789}"
    local peer_token="${3:-}"
    
    echo -e "${BLUE}Joining mesh via ${peer_ip}:${peer_port}...${NC}"
    
    # Request the peer's registry (if they support it)
    # For now, just add the peer to our local registry
    local peer_name
    peer_name="peer-$(echo "$peer_ip" | tr '.' '-')"
    
    init_state
    
    # Add to registry
    local tmp=$(mktemp)
    jq --arg name "$peer_name" --arg ip "$peer_ip" --argjson port "$peer_port" --arg token "$peer_token" \
       '.agents[$name] = {ip:$ip, port:$port, token:$token, role:"peer", hookPath:("/hooks/" + $ARGS.positional[0])}' \
       --args "$MY_AGENT" \
       "$REGISTRY" > "$tmp"
    mv "$tmp" "$REGISTRY"
    
    echo -e "${GREEN}Added ${peer_name} (${peer_ip}:${peer_port}) to registry${NC}"
    echo "Run 'mesh-discover.sh probe' to verify connectivity"
}

# ── Gossip - share routing state with peers ──
cmd_gossip() {
    init_state
    
    echo -e "${BLUE}Gossiping routing state to peers...${NC}"
    
    # Build gossip payload: our view of the mesh
    local gossip_payload
    gossip_payload=$(jq -n -c \
        --arg from "$MY_AGENT" \
        --arg ts "$(get_timestamp)" \
        --slurpfile health "$PEER_HEALTH" \
        --slurpfile routes "$ROUTING_TABLE" \
        '{from:$from, timestamp:$ts, peerHealth:$health[0], routingTable:$routes[0]}')
    
    # Send gossip via MESH notification to all reachable peers
    local mesh_send="$MESH_HOME/bin/mesh-send.sh"
    if [[ -x "$mesh_send" ]]; then
        local reachable_peers
        reachable_peers=$(jq -r 'to_entries[] | select(.value.reachable == true) | .key' "$PEER_HEALTH")
        
        local sent=0
        for peer in $reachable_peers; do
            bash "$mesh_send" "$peer" notification \
                "MESH_GOSSIP:${gossip_payload}" \
                --subject "mesh-gossip" \
                --no-retry 2>/dev/null && sent=$((sent + 1))
        done
        
        echo -e "${GREEN}Gossiped to ${sent} peers${NC}"
    else
        echo -e "${RED}mesh-send.sh not found - can't gossip${NC}"
    fi
}

# ── Main ──

ACTION="${1:-status}"

case "$ACTION" in
    probe)   cmd_probe ;;
    status)  cmd_status ;;
    routes)  cmd_routes ;;
    elect)   cmd_elect ;;
    join)    cmd_join "${2:-}" "${3:-18789}" "${4:-}" ;;
    gossip)  cmd_gossip ;;
    *)
        echo "Usage: mesh-discover.sh {probe|status|routes|elect|join <ip> [port] [token]|gossip}"
        exit 1
        ;;
esac
