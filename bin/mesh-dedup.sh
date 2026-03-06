#!/usr/bin/env bash
# alert-dedup.sh - Alert deduplication for MESH fleet
# 
# Usage: alert-dedup.sh "<alert_text>" [--host <hostname>] [--check <check_name>]
#
# Returns (stdout): new | suppressed | escalate | recovery
# Also outputs JSON on fd 3 with incident details (if fd 3 is open)
#
# This should be called BEFORE processing an alert. Based on the return value:
#   new        → process and notify the operator
#   suppressed → log but don't notify
#   escalate   → status change, notify
#   recovery   → host recovered, always notify

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
        echo "ERROR: Cannot determine MESH_HOME. Set MESH_HOME env var." >&2
        exit 1
    fi
fi
INCIDENTS_FILE="$MESH_HOME/state/active-incidents.json"

# Defaults
ALERT_TEXT="${1:-}"
HOST=""
CHECK=""
DEDUP_WINDOW=1800  # 30 minutes in seconds

shift || true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)  HOST="$2"; shift 2 ;;
        --check) CHECK="$2"; shift 2 ;;
        *) shift ;;
    esac
done

if [[ -z "$ALERT_TEXT" ]]; then
    echo "Usage: alert-dedup.sh \"<alert_text>\" [--host <hostname>] [--check <check_name>]" >&2
    exit 1
fi

# Initialize incidents file if missing
if [[ ! -f "$INCIDENTS_FILE" ]]; then
    echo '{"incidents":[]}' > "$INCIDENTS_FILE"
fi

NOW_EPOCH=$(date +%s)
NOW_ISO=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")

# Try to extract host from alert text if not provided
if [[ -z "$HOST" ]]; then
    # Match IP patterns from alert text
    DETECTED_IP=$(echo "$ALERT_TEXT" | grep -oP '\d+\.\d+\.\d+\.\d+' | head -1 || true)
    if [[ -n "$DETECTED_IP" ]] && [[ -f "${MESH_REGISTRY:-$MESH_HOME/config/agent-registry.json}" ]]; then
        # Reverse-lookup IP in agent registry
        REGISTRY="${MESH_REGISTRY:-$MESH_HOME/config/agent-registry.json}"
        HOST=$(jq -r --arg ip "$DETECTED_IP" '.agents | to_entries[] | select(.value.ip == $ip) | .key' "$REGISTRY" 2>/dev/null | head -1 || true)
    fi
    # Fall back to IP as hostname if no match
    [[ -z "$HOST" ]] && HOST="${DETECTED_IP:-unknown}"
fi

# Try to extract check type from alert text
if [[ -z "$CHECK" ]]; then
    if echo "$ALERT_TEXT" | grep -qi "http.*probe\|gateway\|18789"; then
        CHECK="gateway"
    elif echo "$ALERT_TEXT" | grep -qi "rag\|8900"; then
        CHECK="rag"
    elif echo "$ALERT_TEXT" | grep -qi "bluebubbles\|1234\|imessage"; then
        CHECK="bluebubbles"
    elif echo "$ALERT_TEXT" | grep -qi "tts\|9800\|9802"; then
        CHECK="tts"
    elif echo "$ALERT_TEXT" | grep -qi "image.gen\|9801\|flux"; then
        CHECK="image_gen"
    elif echo "$ALERT_TEXT" | grep -qi "whisper\|stt\|9803"; then
        CHECK="whisper"
    else
        CHECK="unknown"
    fi
fi

# Generate a dedup key from host + check
DEDUP_KEY="${HOST:-unknown}_${CHECK}"

# Check for recovery signals
IS_RECOVERY=false
if echo "$ALERT_TEXT" | grep -qi "resolved\|recovered\|back.online\|back.up\|came.back"; then
    IS_RECOVERY=true
fi

# Look for matching active incident
MATCHING_INCIDENT=$(jq -r --arg key "$DEDUP_KEY" \
    '.incidents[] | select(.dedupKey == $key and .status == "active") | .id' \
    "$INCIDENTS_FILE" 2>/dev/null | head -1)

# Also look for broader network outage incidents
NETWORK_INCIDENT=$(jq -r \
    '.incidents[] | select(.type == "network_outage" and .status == "active") | .id' \
    "$INCIDENTS_FILE" 2>/dev/null | head -1)

if [[ "$IS_RECOVERY" == true ]]; then
    # Recovery - update incident and always notify
    if [[ -n "$MATCHING_INCIDENT" ]]; then
        tmp=$(mktemp)
        jq --arg id "$MATCHING_INCIDENT" --arg now "$NOW_ISO" --arg host "${HOST:-unknown}" \
            '(.incidents[] | select(.id == $id)) |= (
                .status = "resolved" |
                .resolvedAt = $now |
                .lastSeen = $now |
                .alertCount += 1
            )' "$INCIDENTS_FILE" > "$tmp"
        mv "$tmp" "$INCIDENTS_FILE"
    fi
    echo "recovery"
    exit 0
fi

if [[ -n "$NETWORK_INCIDENT" && -n "$HOST" ]]; then
    # Part of a broader network outage - check if this host is already known
    ALREADY_AFFECTED=$(jq -r --arg id "$NETWORK_INCIDENT" --arg host "$HOST" \
        '.incidents[] | select(.id == $id) | .affectedHosts | index($host) != null' \
        "$INCIDENTS_FILE" 2>/dev/null || echo "false")

    LAST_SEEN_EPOCH=$(jq -r --arg id "$NETWORK_INCIDENT" \
        '.incidents[] | select(.id == $id) | .lastSeen' \
        "$INCIDENTS_FILE" 2>/dev/null | xargs -I{} date -d {} +%s 2>/dev/null || echo 0)

    AGE=$((NOW_EPOCH - LAST_SEEN_EPOCH))

    # Update incident
    tmp=$(mktemp)
    if [[ "$ALREADY_AFFECTED" == "true" ]]; then
        jq --arg id "$NETWORK_INCIDENT" --arg now "$NOW_ISO" \
            '(.incidents[] | select(.id == $id)) |= (
                .lastSeen = $now |
                .alertCount += 1
            )' "$INCIDENTS_FILE" > "$tmp"
    else
        jq --arg id "$NETWORK_INCIDENT" --arg now "$NOW_ISO" --arg host "$HOST" \
            '(.incidents[] | select(.id == $id)) |= (
                .lastSeen = $now |
                .alertCount += 1 |
                .affectedHosts += [$host]
            )' "$INCIDENTS_FILE" > "$tmp"
    fi
    mv "$tmp" "$INCIDENTS_FILE"

    # Suppress unless new host or been >2 hours since last alert
    if [[ "$ALREADY_AFFECTED" == "true" && $AGE -lt 7200 ]]; then
        echo "suppressed"
    else
        echo "escalate"
    fi
    exit 0
fi

if [[ -n "$MATCHING_INCIDENT" ]]; then
    # Existing incident for this specific host+check
    LAST_SEEN_EPOCH=$(jq -r --arg id "$MATCHING_INCIDENT" \
        '.incidents[] | select(.id == $id) | .lastSeen' \
        "$INCIDENTS_FILE" 2>/dev/null | xargs -I{} date -d {} +%s 2>/dev/null || echo 0)

    AGE=$((NOW_EPOCH - LAST_SEEN_EPOCH))

    # Update last seen + count
    tmp=$(mktemp)
    jq --arg id "$MATCHING_INCIDENT" --arg now "$NOW_ISO" \
        '(.incidents[] | select(.id == $id)) |= (
            .lastSeen = $now |
            .alertCount += 1
        )' "$INCIDENTS_FILE" > "$tmp"
    mv "$tmp" "$INCIDENTS_FILE"

    if [[ $AGE -lt $DEDUP_WINDOW ]]; then
        echo "suppressed"
    else
        echo "escalate"
    fi
    exit 0
fi

# New incident
INCIDENT_ID="inc_$(date +%Y%m%d)_${DEDUP_KEY}"

# Check if this might be a network-wide issue (multiple hosts down)
# For now, create as individual - the orchestrator can promote to network_outage
AFFECTED_HOSTS="[]"
if [[ -n "$HOST" ]]; then
    AFFECTED_HOSTS=$(jq -n -c --arg h "$HOST" '[$h]')
fi

tmp=$(mktemp)
jq --arg id "$INCIDENT_ID" --arg key "$DEDUP_KEY" --arg now "$NOW_ISO" \
    --arg host "${HOST:-unknown}" --arg check "$CHECK" \
    --argjson affected "$AFFECTED_HOSTS" \
    '.incidents += [{
        id: $id,
        dedupKey: $key,
        type: "service_alert",
        scope: ($host + "/" + $check),
        firstSeen: $now,
        lastSeen: $now,
        alertCount: 1,
        affectedHosts: $affected,
        status: "active",
        escalated: false,
        lastNotifiedOperator: null
    }]' "$INCIDENTS_FILE" > "$tmp"
mv "$tmp" "$INCIDENTS_FILE"

echo "new"
