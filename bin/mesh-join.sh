#!/usr/bin/env bash
# mesh-join.sh - Add a peer to this node's mesh registry
# Makes the "clone + install + join" workflow dead simple.
#
# Usage:
#   mesh-join.sh <name> <ip> [port] [token]
#   mesh-join.sh alpha 192.168.1.10                     # defaults: port 18789, auto-gen token
#   mesh-join.sh alpha 192.168.1.10 18789 my-token      # explicit
#   mesh-join.sh --show                                  # Show this node's join command for others
#
# Two-VM setup:
#   VM1$ bash install.sh --agent alpha --hub
#   VM1$ mesh-join.sh beta 192.168.1.11
#   VM1$ mesh-join.sh --show   # prints the command for VM2
#
#   VM2$ bash install.sh --agent beta
#   VM2$ mesh-join.sh alpha 192.168.1.10 18789 <token from VM1's --show>
#
#   Both$ mesh-discover.sh probe   # verify connectivity

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

if [ -n "${MESH_AGENT:-}" ]; then
    MY_AGENT="$MESH_AGENT"
elif [ -f "$MESH_HOME/config/identity" ]; then
    MY_AGENT="$(cat "$MESH_HOME/config/identity" | tr -d '[:space:]')"
else
    MY_AGENT="${USER:-unknown}"
fi

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Show this node's join info
if [[ "${1:-}" == "--show" ]]; then
    my_ip=$(jq -r --arg a "$MY_AGENT" '.agents[$a].ip // empty' "$REGISTRY" 2>/dev/null || hostname -I | awk '{print $1}')
    my_port=$(jq -r --arg a "$MY_AGENT" '.agents[$a].port // 18789' "$REGISTRY" 2>/dev/null || echo "18789")
    my_token=$(jq -r --arg a "$MY_AGENT" '.agents[$a].token // "UNKNOWN"' "$REGISTRY" 2>/dev/null || echo "UNKNOWN")
    
    echo -e "${CYAN}This node: ${MY_AGENT}${NC}"
    echo -e "  IP:    ${my_ip}"
    echo -e "  Port:  ${my_port}"
    echo -e "  Token: ${my_token}"
    echo ""
    echo -e "${GREEN}Run this on the other node to join:${NC}"
    echo ""
    echo "  mesh-join.sh ${MY_AGENT} ${my_ip} ${my_port} ${my_token}"
    echo ""
    exit 0
fi

# Validate args
if [[ $# -lt 2 ]]; then
    echo "Usage: mesh-join.sh <name> <ip> [port] [token]"
    echo "       mesh-join.sh --show    # Show this node's join info"
    exit 1
fi

PEER_NAME="$1"
PEER_IP="$2"
PEER_PORT="${3:-18789}"
PEER_TOKEN="${4:-mesh-$(openssl rand -hex 12 2>/dev/null || echo "changeme-$(date +%s)")}"

# Check if peer already exists
if jq -e ".agents.${PEER_NAME}" "$REGISTRY" > /dev/null 2>&1; then
    echo -e "${YELLOW}Peer '${PEER_NAME}' already exists in registry - updating${NC}"
fi

# Add peer to registry
tmp=$(mktemp)
jq --arg name "$PEER_NAME" \
   --arg ip "$PEER_IP" \
   --argjson port "$PEER_PORT" \
   --arg token "$PEER_TOKEN" \
   --arg hookPath "/hooks/${MY_AGENT}" \
   '.agents[$name] = {ip:$ip, port:$port, token:$token, role:"peer", hookPath:$hookPath, signing:false}' \
   "$REGISTRY" > "$tmp"
mv "$tmp" "$REGISTRY"
chmod 600 "$REGISTRY"

echo -e "${GREEN}✓ Added peer '${PEER_NAME}' (${PEER_IP}:${PEER_PORT})${NC}"
echo ""

# Test connectivity
echo -n "Testing connectivity... "
http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 3 --max-time 5 \
    -X POST "http://${PEER_IP}:${PEER_PORT}/hooks/${MY_AGENT}" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${PEER_TOKEN}" \
    -d '{"message":"ping"}' 2>/dev/null || echo "000")

if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    echo -e "${GREEN}✓ Reachable (HTTP ${http_code})${NC}"
elif [[ "$http_code" == "000" ]]; then
    echo -e "${YELLOW}✗ Connection refused - is the agent running on ${PEER_IP}:${PEER_PORT}?${NC}"
else
    echo -e "${YELLOW}✗ HTTP ${http_code} - check token and hook config${NC}"
fi

echo ""
my_ip=$(jq -r --arg a "$MY_AGENT" '.agents[$a].ip // "YOUR_IP"' "$REGISTRY")
my_port=$(jq -r --arg a "$MY_AGENT" '.agents[$a].port // 18789' "$REGISTRY")
my_token=$(jq -r --arg a "$MY_AGENT" '.agents[$a].token // "YOUR_TOKEN"' "$REGISTRY")

echo -e "${CYAN}Next steps:${NC}"
echo "  1. On the other node, run: mesh-join.sh ${MY_AGENT} ${my_ip} ${my_port} ${my_token}"
echo "  2. Verify: mesh-discover.sh probe"
echo "  3. Send:   mesh-send.sh ${PEER_NAME} notification \"Hello from ${MY_AGENT}\""
