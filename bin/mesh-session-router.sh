#!/usr/bin/env bash
# mesh-session-router.sh - Persistent collaborative sessions for MESH
#
# Maintains conversation context across multiple MESH exchanges between agents.
# Each session is stored locally as a JSON file with full message history.
# Fully decentralized - no central session store needed.
#
# Usage:
#   # Process an inbound MESH message (call from hook handler)
#   mesh-session-router.sh receive "$envelope"
#
#   # Start a new collaborative session
#   mesh-session-router.sh start <session-key> <agents...>
#
#   # Send a message within a session (fans out to ALL participants, like a group email)
#   mesh-session-router.sh send <session-key> <agent> <message>
#
#   # Get session context (for feeding to an agent as system context)
#   mesh-session-router.sh context <session-key> [--max-messages 20]
#
#   # List active sessions
#   mesh-session-router.sh list [--active|--all]
#
#   # Close/archive a session
#   mesh-session-router.sh close <session-key>
#
# Sessions dir: $MESH_HOME/sessions/

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

SESSIONS_DIR="$MESH_HOME/sessions"
mkdir -p "$SESSIONS_DIR"

if [ -n "${MESH_AGENT:-}" ]; then
    MY_AGENT="$MESH_AGENT"
elif [ -f "$MESH_HOME/config/identity" ]; then
    MY_AGENT="$(cat "$MESH_HOME/config/identity" | tr -d '[:space:]')"
else
    MY_AGENT="${USER:-unknown}"
fi

# Colors
G='\033[0;32m'; Y='\033[0;33m'; C='\033[0;36m'; R='\033[0;31m'; D='\033[0;90m'; NC='\033[0m'

MAX_SESSION_MESSAGES=${MESH_MAX_SESSION_MESSAGES:-50}
SESSION_TTL_HOURS=${MESH_SESSION_TTL_HOURS:-24}

# ── Helpers ──

_session_file() {
    local key="$1"
    # Sanitize key for filename
    local safe_key
    safe_key=$(echo "$key" | sed 's/[^a-zA-Z0-9._-]/_/g')
    echo "$SESSIONS_DIR/${safe_key}.json"
}

_init_session() {
    local key="$1"
    local file
    file=$(_session_file "$key")
    
    if [[ ! -f "$file" ]]; then
        local now_iso
        now_iso=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
        jq -n \
            --arg key "$key" \
            --arg created "$now_iso" \
            --arg agent "$MY_AGENT" \
            '{
                sessionKey: $key,
                created: $created,
                lastActivity: $created,
                status: "active",
                participants: [$agent],
                messages: []
            }' > "$file"
        chmod 600 "$file"
    fi
    echo "$file"
}

_add_participant() {
    local file="$1"
    local agent="$2"
    local tmp
    tmp=$(mktemp)
    jq --arg a "$agent" '
        if (.participants | index($a)) then . 
        else .participants += [$a] 
        end
    ' "$file" > "$tmp" && mv "$tmp" "$file"
}

_append_message() {
    local file="$1"
    local from="$2"
    local to="$3"
    local type="$4"
    local subject="$5"
    local body="$6"
    local msg_id="${7:-}"
    local correlation_id="${8:-}"
    
    local now_iso
    now_iso=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
    
    local tmp
    tmp=$(mktemp)
    jq --arg from "$from" \
       --arg to "$to" \
       --arg type "$type" \
       --arg subject "$subject" \
       --arg body "$body" \
       --arg ts "$now_iso" \
       --arg msgId "$msg_id" \
       --arg corrId "$correlation_id" \
       --argjson max "$MAX_SESSION_MESSAGES" \
       '
        .messages += [{
            from: $from,
            to: $to,
            type: $type,
            subject: $subject,
            body: $body,
            timestamp: $ts,
            msgId: $msgId,
            correlationId: $corrId
        }] |
        .lastActivity = $ts |
        # Trim to max messages (keep most recent)
        if (.messages | length) > $max then
            .messages = .messages[-$max:]
        else . end
    ' "$file" > "$tmp" && mv "$tmp" "$file"
}

_get_context() {
    local file="$1"
    local max="${2:-20}"
    
    if [[ ! -f "$file" ]]; then
        echo "[]"
        return
    fi
    
    jq --argjson max "$max" '.messages[-$max:]' "$file"
}

_format_context_for_agent() {
    local file="$1"
    local max="${2:-20}"
    
    if [[ ! -f "$file" ]]; then
        echo ""
        return
    fi
    
    local session_key
    session_key=$(jq -r '.sessionKey' "$file")
    local participants
    participants=$(jq -r '.participants | join(", ")' "$file")
    
    echo "=== MESH Collaborative Session: $session_key ==="
    echo "Participants: $participants"
    echo "---"
    
    jq -r --argjson max "$max" '
        .messages[-$max:] | .[] |
        "[\(.timestamp | split("T")[1] | split(".")[0])] \(.from) → \(.to) [\(.type)]: \(.subject)\n\(.body)\n"
    ' "$file" 2>/dev/null
}

# ── Commands ──

cmd_receive() {
    local envelope="${1:-}"
    
    if [[ -z "$envelope" ]]; then
        envelope=$(cat)
    fi
    
    # Parse envelope
    local session_key from to msg_type subject body msg_id correlation_id
    session_key=$(echo "$envelope" | jq -r '.session.key // empty')
    
    # No session key = not a collaborative session, pass through
    if [[ -z "$session_key" ]]; then
        echo "NO_SESSION"
        return 0
    fi
    
    from=$(echo "$envelope" | jq -r '.from // "unknown"')
    to=$(echo "$envelope" | jq -r '.to // "unknown"')
    msg_type=$(echo "$envelope" | jq -r '.type // "message"')
    subject=$(echo "$envelope" | jq -r '.payload.subject // ""')
    body=$(echo "$envelope" | jq -r '.payload.body // ""')
    msg_id=$(echo "$envelope" | jq -r '.id // ""')
    correlation_id=$(echo "$envelope" | jq -r '.correlationId // ""')
    
    # Initialize or get session
    local file
    file=$(_init_session "$session_key")
    
    # Add sender as participant
    _add_participant "$file" "$from"
    _add_participant "$file" "$to"
    
    # Append message to session history
    _append_message "$file" "$from" "$to" "$msg_type" "$subject" "$body" "$msg_id" "$correlation_id"
    
    # Output the context for the agent to use
    echo "SESSION_KEY=$session_key"
    echo "SESSION_FILE=$file"
    echo "SESSION_MESSAGES=$(jq '.messages | length' "$file")"
    echo "SESSION_PARTICIPANTS=$(jq -r '.participants | join(",")' "$file")"
    
    # Output formatted context to stderr (for agent consumption)
    _format_context_for_agent "$file" 20 >&2
}

cmd_start() {
    local session_key="${1:?Session key required}"
    shift
    local agents=("$@")
    
    local file
    file=$(_init_session "$session_key")
    
    for agent in "${agents[@]}"; do
        _add_participant "$file" "$agent"
    done
    
    echo -e "${G}✓ Session '${session_key}' created${NC}"
    echo -e "  Participants: ${C}$(jq -r '.participants | join(", ")' "$file")${NC}"
    echo -e "  File: ${D}${file}${NC}"
}

cmd_send() {
    local session_key="${1:?Session key required}"
    local target="${2:?Target agent required}"
    local message="${3:?Message required}"
    local subject="${4:-}"
    
    # Ensure session exists
    local file
    file=$(_init_session "$session_key")
    _add_participant "$file" "$target"
    
    # Record outbound message FIRST (so it's in context)
    # In group mode, target is "all" - record as broadcast
    _append_message "$file" "$MY_AGENT" "$target" "request" "${subject:-$message}" "$message"
    
    # NOTE: mesh-send.sh also auto-records via session router on success.
    # To prevent duplicates, we set a flag that mesh-send.sh checks.
    export _MESH_SESSION_ALREADY_RECORDED=1
    
    # Build embedded session context
    local msg_count
    msg_count=$(jq '.messages | length' "$file")
    
    local session_context_json
    session_context_json=$(jq -c '.messages[-10:] | [.[] | {from,to,body,timestamp}]' "$file" 2>/dev/null || echo "[]")
    
    # Get all participants for the session
    local all_participants
    all_participants=$(jq -r '.participants[]' "$file" 2>/dev/null)
    
    # Build metadata with embedded context (structured, for programmatic use)
    local participants_json
    participants_json=$(jq -c '.participants' "$file" 2>/dev/null || echo "[]")
    local meta
    meta=$(jq -n --argjson ctx "$session_context_json" --arg key "$session_key" --argjson participants "$participants_json" \
        '{"sessionContext": $ctx, "sessionKey": $key, "participants": $participants}')
    
    # Build human-readable context prefix (for AI agents to understand)
    local body_with_context="$message"
    if [[ $msg_count -gt 1 ]]; then
        local readable_context
        readable_context=$(jq -r '.messages[-10:-1] | .[] | 
            "[\(.from) → \(.to)]: \(.body[0:200])"
        ' "$file" 2>/dev/null)
        
        body_with_context="[Collaborative Session: ${session_key} - ${msg_count} messages]
[Participants: $(jq -r '.participants | join(", ")' "$file")]
[Prior conversation:]
${readable_context}
---
[Current message from ${MY_AGENT}:]
${message}

[NOTE: This is a group session. All participants see all messages. Reply to contribute - your response will be shared with everyone in the session.]"
    fi
    
    # Fan out to ALL participants (except sender) - true group chat
    local sent_count=0
    while IFS= read -r participant; do
        # Skip self
        [[ "$participant" == "$MY_AGENT" ]] && continue
        
        local send_output
        send_output=$(bash "$MESH_HOME/bin/mesh-send.sh" "$participant" request "$body_with_context" \
            --session-key "$session_key" \
            --metadata "$meta" \
            ${subject:+--subject "$subject"} 2>&1)
        echo "$send_output"
        sent_count=$((sent_count + 1))
    done <<< "$all_participants"
    
    if [[ $sent_count -eq 0 ]]; then
        echo -e "${Y}Warning: No other participants to send to${NC}" >&2
    fi
}

cmd_context() {
    local session_key="${1:?Session key required}"
    local max="${2:-20}"
    
    local file
    file=$(_session_file "$session_key")
    
    if [[ ! -f "$file" ]]; then
        echo -e "${R}Session '${session_key}' not found${NC}" >&2
        return 1
    fi
    
    _format_context_for_agent "$file" "$max"
}

cmd_list() {
    local filter="${1:---active}"
    local now_epoch
    now_epoch=$(date +%s)
    local ttl_seconds=$((SESSION_TTL_HOURS * 3600))
    
    echo -e "${C}MESH Collaborative Sessions${NC}"
    echo -e "${D}─────────────────────────────────────────${NC}"
    
    local count=0
    for file in "$SESSIONS_DIR"/*.json; do
        [[ -f "$file" ]] || continue
        
        local key status last_activity msg_count participants
        key=$(jq -r '.sessionKey' "$file")
        status=$(jq -r '.status' "$file")
        last_activity=$(jq -r '.lastActivity' "$file")
        msg_count=$(jq '.messages | length' "$file")
        participants=$(jq -r '.participants | join(", ")' "$file")
        
        # Check if expired
        local last_epoch
        last_epoch=$(date -d "$last_activity" +%s 2>/dev/null || echo 0)
        local age=$((now_epoch - last_epoch))
        
        if [[ "$filter" == "--active" && ("$status" != "active" || $age -gt $ttl_seconds) ]]; then
            continue
        fi
        
        local status_icon
        if [[ "$status" == "active" && $age -le $ttl_seconds ]]; then
            status_icon="${G}●${NC}"
        elif [[ "$status" == "closed" ]]; then
            status_icon="${D}○${NC}"
        else
            status_icon="${Y}◐${NC}"
        fi
        
        # Age display
        local age_display
        if [[ $age -lt 3600 ]]; then
            age_display="$((age / 60))m ago"
        elif [[ $age -lt 86400 ]]; then
            age_display="$((age / 3600))h ago"
        else
            age_display="$((age / 86400))d ago"
        fi
        
        echo -e "  ${status_icon} ${C}${key}${NC} - ${msg_count} msgs - ${participants} - ${D}${age_display}${NC}"
        count=$((count + 1))
    done
    
    if [[ $count -eq 0 ]]; then
        echo -e "  ${D}No sessions found${NC}"
    fi
}

cmd_close() {
    local session_key="${1:?Session key required}"
    local file
    file=$(_session_file "$session_key")
    
    if [[ ! -f "$file" ]]; then
        echo -e "${R}Session '${session_key}' not found${NC}"
        return 1
    fi
    
    local tmp
    tmp=$(mktemp)
    jq '.status = "closed"' "$file" > "$tmp" && mv "$tmp" "$file"
    
    echo -e "${G}✓ Session '${session_key}' closed${NC}"
    echo -e "  Messages: $(jq '.messages | length' "$file")"
    echo -e "  Participants: $(jq -r '.participants | join(", ")' "$file")"
}

cmd_cleanup() {
    # Remove expired sessions older than TTL
    local now_epoch
    now_epoch=$(date +%s)
    local ttl_seconds=$((SESSION_TTL_HOURS * 3600))
    local removed=0
    
    for file in "$SESSIONS_DIR"/*.json; do
        [[ -f "$file" ]] || continue
        local last_activity
        last_activity=$(jq -r '.lastActivity' "$file" 2>/dev/null)
        local last_epoch
        last_epoch=$(date -d "$last_activity" +%s 2>/dev/null || echo 0)
        local age=$((now_epoch - last_epoch))
        
        if [[ $age -gt $ttl_seconds ]]; then
            rm -f "$file"
            removed=$((removed + 1))
        fi
    done
    
    echo -e "${G}Cleaned up ${removed} expired sessions${NC}"
}

# ── Main ──

cmd="${1:-help}"
shift || true

case "$cmd" in
    receive)  cmd_receive "$@" ;;
    start)    cmd_start "$@" ;;
    send)     cmd_send "$@" ;;
    context)  cmd_context "$@" ;;
    list)     cmd_list "$@" ;;
    close)    cmd_close "$@" ;;
    cleanup)  cmd_cleanup ;;
    help|*)
        echo "mesh-session-router.sh - Persistent collaborative sessions"
        echo ""
        echo "Commands:"
        echo "  receive <envelope>               Process inbound MESH message"
        echo "  start <key> <agent1> [agent2..]  Start a new session"
        echo "  send <key> <agent> <message>     Send within a session (includes context)"
        echo "  context <key> [max_messages]     Get session context"
        echo "  list [--active|--all]            List sessions"
        echo "  close <key>                      Close a session"
        echo "  cleanup                          Remove expired sessions"
        echo ""
        echo "Env:"
        echo "  MESH_MAX_SESSION_MESSAGES  Max messages per session (default: 50)"
        echo "  MESH_SESSION_TTL_HOURS     Session expiry (default: 24)"
        ;;
esac
