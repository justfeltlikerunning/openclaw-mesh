#!/bin/bash
# MESH Protocol - Installer
# Sets up a complete MESH node with peer-to-peer messaging, 
# queue persistence, discovery, and relay failover.
#
# Usage:
#   bash install.sh                           # Interactive install
#   bash install.sh --agent myagent           # Non-interactive with agent name
#   bash install.sh --agent myagent --hub     # Install as hub node
#   MESH_HOME=/custom/path bash install.sh    # Custom install path
#
# After install:
#   1. Add peers to config/agent-registry.json
#   2. Run: mesh-keygen.sh <peer> to generate signing keys
#   3. Exchange keys with peers (scp config/signing-keys/<peer>.key)
#   4. Run: mesh-discover.sh probe to verify connectivity

set -euo pipefail

MESH_VERSION="2.0.0"
DEFAULT_MESH_HOME="${MESH_HOME:-$HOME/.mesh}"
AGENT_NAME="${MESH_AGENT:-}"
IS_HUB=false
INSTALL_TIMERS=true

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --agent)       AGENT_NAME="$2"; shift 2 ;;
        --home)        DEFAULT_MESH_HOME="$2"; shift 2 ;;
        --hub)         IS_HUB=true; shift ;;
        --no-timers)   INSTALL_TIMERS=false; shift ;;
        --check)
            echo "🐝 MESH Dependency Check"
            echo ""
            OK=true
            for cmd in bash jq curl; do
                if command -v "$cmd" >/dev/null 2>&1; then
                    ver=$("$cmd" --version 2>&1 | head -1)
                    echo "  ✓ $cmd  ($ver)"
                else
                    echo "  ✗ $cmd  MISSING - install with: apt install $cmd"
                    OK=false
                fi
            done
            echo ""
            for cmd in openssl python3 file uuidgen base64; do
                if command -v "$cmd" >/dev/null 2>&1; then
                    echo "  ✓ $cmd  (optional)"
                else
                    echo "  ○ $cmd  not found (optional - signing/attachments need openssl)"
                fi
            done
            echo ""
            $OK && echo "All required dependencies met ✅" || echo "Missing required dependencies ❌"
            exit 0
            ;;
        --help)
            echo "MESH Protocol Installer v${MESH_VERSION}"
            echo ""
            echo "Usage: bash install.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --agent <name>    Set this agent's identity (required)"
            echo "  --home <path>     Install path (default: ~/.mesh)"
            echo "  --hub             Install as hub node (elected relay coordinator)"
            echo "  --no-timers       Skip systemd timer setup"
            echo "  --check           Check dependencies without installing"
            echo "  --help            Show this help"
            echo ""
            echo "After install, add peers to config/agent-registry.json and run:"
            echo "  mesh-discover.sh probe"
            exit 0
            ;;
        *) echo "Unknown option: $1"; shift ;;
    esac
done

echo "🐝  MESH Protocol Installer v${MESH_VERSION}"
echo "==========================================="
echo ""

# Get agent name
if [[ -z "$AGENT_NAME" ]]; then
    read -p "Agent name for this host (e.g., 'myagent'): " AGENT_NAME
fi

if [[ -z "$AGENT_NAME" ]]; then
    echo "❌ Agent name is required"
    exit 1
fi

MESH_HOME="$DEFAULT_MESH_HOME"
echo "📁 Installing to: $MESH_HOME"
echo "🆔 Agent identity: $AGENT_NAME"
echo "🏗️  Role: $( $IS_HUB && echo "HUB" || echo "peer" )"
echo ""

# Create directory structure
mkdir -p "$MESH_HOME"/{bin,config/signing-keys,config/encryption-keys,state,logs,sessions}

# Copy scripts
INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for script in mesh-send.sh mesh-queue.sh mesh-discover.sh mesh-rally.sh mesh-dedup.sh \
              mesh-receive.sh mesh-reply.sh mesh-keygen.sh mesh-track.sh mesh-brain-sync.sh \
              mesh-join.sh mesh-status.sh mesh-export.sh mesh-crypt.sh mesh-session-router.sh mesh-collab.sh; do
    if [[ -f "$INSTALLER_DIR/bin/${script}" ]]; then
        cp "$INSTALLER_DIR/bin/${script}" "$MESH_HOME/bin/"
    fi
done

chmod +x "$MESH_HOME/bin/"*.sh 2>/dev/null || true

# Copy generic receiver for non-OpenClaw integrations
if [[ -d "$INSTALLER_DIR/examples/receivers" ]]; then
    mkdir -p "$MESH_HOME/receivers"
    cp "$INSTALLER_DIR/examples/receivers/generic-receiver.py" "$MESH_HOME/receivers/" 2>/dev/null || true
    cp "$INSTALLER_DIR/examples/receivers/handler-example.sh" "$MESH_HOME/receivers/" 2>/dev/null || true
    chmod +x "$MESH_HOME/receivers/"*.sh 2>/dev/null || true
fi

# Set agent identity
echo "$AGENT_NAME" > "$MESH_HOME/config/identity"

# Initialize state files
[[ -f "$MESH_HOME/state/circuit-breakers.json" ]] || echo '{}' > "$MESH_HOME/state/circuit-breakers.json"
[[ -f "$MESH_HOME/state/dead-letters.json" ]]     || echo '{"messages":[]}' > "$MESH_HOME/state/dead-letters.json"
[[ -f "$MESH_HOME/state/active-incidents.json" ]]  || echo '{"incidents":[]}' > "$MESH_HOME/state/active-incidents.json"
[[ -f "$MESH_HOME/state/queue-state.json" ]]       || echo '{"lastDrain":null,"totalReplayed":0,"totalPurged":0}' > "$MESH_HOME/state/queue-state.json"
[[ -f "$MESH_HOME/state/routing-table.json" ]]     || jq -n \
    --arg agent "$AGENT_NAME" \
    --argjson hub "$($IS_HUB && echo "\"$AGENT_NAME\"" || echo "null")" \
    '{version:2, lastUpdated:null, self:$agent, hub:$hub, relay:null, meshHealth:{up:0,down:0,total:0}}' \
    > "$MESH_HOME/state/routing-table.json"
[[ -f "$MESH_HOME/state/peer-health.json" ]]       || echo '{}' > "$MESH_HOME/state/peer-health.json"
touch "$MESH_HOME/logs/mesh-audit.jsonl" "$MESH_HOME/logs/queue-replay.jsonl" "$MESH_HOME/logs/discover.jsonl"

# Create agent registry if it doesn't exist
local_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo '127.0.0.1')
if [[ ! -f "$MESH_HOME/config/agent-registry.json" ]]; then
    role="peer"
    $IS_HUB && role="hub"
    
    cat > "$MESH_HOME/config/agent-registry.json" << REGEOF
{
  "version": "2.0",
  "agents": {
    "$AGENT_NAME": {
      "ip": "$local_ip",
      "port": 18789,
      "token": "mesh-$(openssl rand -hex 12 2>/dev/null || echo 'changeme-$(date +%s)')",
      "role": "$role",
      "hookPath": "/hooks",
      "signing": false
    }
  }
}
REGEOF
    echo "📋 Created agent registry with this host"
fi

# Set permissions on sensitive files
chmod 600 "$MESH_HOME/config/agent-registry.json" 2>/dev/null || true
chmod 700 "$MESH_HOME/config/signing-keys" 2>/dev/null || true

# Install systemd timers (if systemd is available)
if [[ "$INSTALL_TIMERS" == true ]] && command -v systemctl >/dev/null 2>&1; then
    SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
    mkdir -p "$SYSTEMD_USER_DIR"
    
    # Queue drain timer (every 60s)
    cat > "$SYSTEMD_USER_DIR/mesh-queue.service" << SVCEOF
[Unit]
Description=MESH Message Queue Drain

[Service]
Type=oneshot
Environment=MESH_HOME=$MESH_HOME
Environment=MESH_AGENT=$AGENT_NAME
ExecStart=/usr/bin/bash $MESH_HOME/bin/mesh-queue.sh drain
StandardOutput=journal
StandardError=journal
SVCEOF

    cat > "$SYSTEMD_USER_DIR/mesh-queue.timer" << TMREOF
[Unit]
Description=MESH Queue Drain Timer

[Timer]
OnBootSec=30
OnUnitActiveSec=60
AccuracySec=5

[Install]
WantedBy=timers.target
TMREOF

    # Peer discovery timer (every 5 minutes)
    cat > "$SYSTEMD_USER_DIR/mesh-discover.service" << SVCEOF
[Unit]
Description=MESH Peer Discovery Probe

[Service]
Type=oneshot
Environment=MESH_HOME=$MESH_HOME
Environment=MESH_AGENT=$AGENT_NAME
ExecStart=/usr/bin/bash $MESH_HOME/bin/mesh-discover.sh probe
ExecStartPost=/usr/bin/bash $MESH_HOME/bin/mesh-discover.sh elect
StandardOutput=journal
StandardError=journal
SVCEOF

    cat > "$SYSTEMD_USER_DIR/mesh-discover.timer" << TMREOF
[Unit]
Description=MESH Peer Discovery Timer

[Timer]
OnBootSec=60
OnUnitActiveSec=300
AccuracySec=10

[Install]
WantedBy=timers.target
TMREOF

    systemctl --user daemon-reload
    systemctl --user enable --now mesh-queue.timer 2>/dev/null || true
    systemctl --user enable --now mesh-discover.timer 2>/dev/null || true
    
    echo "⏱️  Installed systemd timers:"
    echo "   mesh-queue.timer    - drains dead letters every 60s"
    echo "   mesh-discover.timer - probes peers + elects relay every 5min"
fi

# Generate shell profile snippet
PROFILE_SNIPPET="# MESH Protocol
export MESH_HOME=\"$MESH_HOME\"
export MESH_AGENT=\"$AGENT_NAME\"
export PATH=\"\$MESH_HOME/bin:\$PATH\""

echo ""
echo "✅ MESH Protocol v${MESH_VERSION} installed!"
echo ""
echo "📁 Install path:    $MESH_HOME"
echo "🆔 Agent identity:  $AGENT_NAME"
echo "🌐 Local IP:        $local_ip"
echo "🏗️  Role:            $( $IS_HUB && echo "HUB (relay coordinator)" || echo "Peer" )"
echo ""
echo "Add to ~/.bashrc:"
echo "─────────────────────────────────"
echo "$PROFILE_SNIPPET"
echo "─────────────────────────────────"
echo ""
echo "📖 Next steps:"
echo "  1. Add peers:     Edit $MESH_HOME/config/agent-registry.json"
echo "  2. Generate keys: mesh-keygen.sh <peer-name>"
echo "  3. Exchange keys: scp config/signing-keys/<peer>.key peer:/path/signing-keys/$(echo $AGENT_NAME).key"
echo "  4. Verify mesh:   mesh-discover.sh probe"
echo "  5. Send message:  mesh-send.sh <peer> request \"Hello from $AGENT_NAME\""
echo ""
echo "📚 Docs: https://github.com/justfeltlikerunning/openclaw-mesh"
