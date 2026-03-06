#!/usr/bin/env bash
# mesh-keygen.sh - Generate signing keys for MESH agent pairs
#
# Usage:
#   mesh-keygen.sh <agent-name>          Generate a key for communicating with <agent>
#   mesh-keygen.sh --all                 Generate keys for all agents in registry
#   mesh-keygen.sh --show <agent-name>   Show existing key for an agent
#
# Keys are stored in: $MESH_HOME/config/signing-keys/<agent>.key
# Both agents in a pair must have the SAME key. After generating,
# copy the key file to the other agent's config/signing-keys/ directory.
#
# To enable signing for an agent, set "signing": true in agent-registry.json

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
    if [ -n "$SCRIPT_DIR" ]; then
        MESH_HOME="$(dirname "$SCRIPT_DIR")"
    elif [ -f "$HOME/openclaw-mesh/config/agent-registry.json" ]; then
        MESH_HOME="$HOME/openclaw-mesh"
    else
        echo "ERROR: Cannot determine MESH_HOME." >&2; exit 1
    fi
fi
REGISTRY="${MESH_REGISTRY:-$MESH_HOME/config/agent-registry.json}"
KEY_DIR="$MESH_HOME/config/signing-keys"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

usage() {
    echo "Usage: mesh-keygen.sh <agent-name> | --all | --show <agent>"
    echo ""
    echo "Commands:"
    echo "  <agent>        Generate a new 256-bit signing key for agent pair"
    echo "  --all          Generate keys for all agents in registry"
    echo "  --show <agent> Display existing key for an agent"
    echo "  --status       Show signing status for all agents"
    echo ""
    echo "Keys stored in: $KEY_DIR/"
    echo ""
    echo "After generating, copy the key to the other agent:"
    echo "  scp $KEY_DIR/<agent>.key <agent>@<ip>:~/openclaw-mesh/config/signing-keys/<my-name>.key"
    exit 1
}

generate_key() {
    local agent="$1"
    mkdir -p "$KEY_DIR"
    chmod 700 "$KEY_DIR"

    local keyfile="$KEY_DIR/${agent}.key"

    if [[ -f "$keyfile" ]]; then
        echo -e "${YELLOW}Key already exists for ${agent}. Overwrite? (y/N)${NC}"
        read -r confirm
        [[ "$confirm" == "y" || "$confirm" == "Y" ]] || { echo "Skipped."; return 0; }
    fi

    # Generate 256-bit (32 byte) random key, hex encoded
    local key
    key=$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | xxd -p -c 64)

    echo -n "$key" > "$keyfile"
    chmod 600 "$keyfile"

    echo -e "${GREEN}✓ Generated signing key for ${agent}${NC}"
    echo -e "  Key file: ${keyfile}"
    echo -e "  Key: ${BLUE}${key:0:16}...${NC} (${#key} hex chars = 256 bits)"
    echo ""
    echo -e "  ${YELLOW}Next steps:${NC}"
    echo -e "  1. Enable signing in agent-registry.json:"
    echo -e "     \"${agent}\": { ..., \"signing\": true }"
    echo -e "  2. Copy this key to ${agent}'s MESH install:"

    # Try to get agent IP from registry
    local ip
    ip=$(jq -r ".agents.${agent}.ip // \"<ip>\"" "$REGISTRY" 2>/dev/null || echo "<ip>")
    local my_agent="${MESH_AGENT:-$(cat "$MESH_HOME/config/identity" 2>/dev/null || echo "myagent")}"
    echo -e "     scp ${keyfile} ${agent}@${ip}:~/openclaw-mesh/config/signing-keys/${my_agent}.key"
}

show_key() {
    local agent="$1"
    local keyfile="$KEY_DIR/${agent}.key"

    if [[ ! -f "$keyfile" ]]; then
        echo -e "${RED}No key found for ${agent}${NC}"
        echo "  Expected at: $keyfile"
        return 1
    fi

    local key
    key=$(cat "$keyfile")
    echo -e "${GREEN}Signing key for ${agent}:${NC}"
    echo -e "  File: $keyfile"
    echo -e "  Key: ${key}"
    echo -e "  Length: ${#key} hex chars ($(( ${#key} * 4 )) bits)"
}

show_status() {
    echo -e "${BLUE}🐝 MESH Signing Status${NC}"
    echo ""

    if [[ ! -f "$REGISTRY" ]]; then
        echo -e "${RED}No agent registry found at $REGISTRY${NC}"
        return 1
    fi

    local agents
    agents=$(jq -r '.agents | keys[]' "$REGISTRY" 2>/dev/null)

    printf "  %-15s %-10s %-10s %s\n" "Agent" "Signing" "Key" "Status"
    printf "  %-15s %-10s %-10s %s\n" "─────" "───────" "───" "──────"

    for agent in $agents; do
        local signing_enabled
        signing_enabled=$(jq -r ".agents.${agent}.signing // false" "$REGISTRY")
        local has_key="no"
        [[ -f "$KEY_DIR/${agent}.key" ]] && has_key="yes"

        local status=""
        if [[ "$signing_enabled" == "true" && "$has_key" == "yes" ]]; then
            status="${GREEN}✓ Ready${NC}"
        elif [[ "$signing_enabled" == "true" && "$has_key" == "no" ]]; then
            status="${RED}✗ Missing key${NC}"
        elif [[ "$signing_enabled" == "false" && "$has_key" == "yes" ]]; then
            status="${YELLOW}○ Key exists, signing disabled${NC}"
        else
            status="– Not configured"
        fi

        printf "  %-15s %-10s %-10s " "$agent" "$signing_enabled" "$has_key"
        echo -e "$status"
    done
}

# ── Main ──

[[ $# -lt 1 ]] && usage

case "$1" in
    --all)
        if [[ ! -f "$REGISTRY" ]]; then
            echo -e "${RED}No registry found at $REGISTRY${NC}"
            exit 1
        fi
        agents=$(jq -r '.agents | keys[]' "$REGISTRY")
        my_agent="${MESH_AGENT:-$(cat "$MESH_HOME/config/identity" 2>/dev/null || echo "")}"
        for agent in $agents; do
            [[ "$agent" == "$my_agent" ]] && continue
            generate_key "$agent"
            echo ""
        done
        ;;
    --show)
        [[ $# -lt 2 ]] && usage
        show_key "$2"
        ;;
    --status)
        show_status
        ;;
    --help|-h)
        usage
        ;;
    *)
        generate_key "$1"
        ;;
esac
