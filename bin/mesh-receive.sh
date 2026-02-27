#!/usr/bin/env bash
# mesh-receive.sh - Parse, verify, and handle incoming MESH protocol messages
#
# Usage: source this in processing scripts, or call directly:
#   mesh-receive.sh "<message_text>"
#
# Outputs (on stdout as KEY=VALUE):
#   MESH_DETECTED=true|false
#   MESH_ID=msg_xxx
#   MESH_FROM=worker-a
#   MESH_TO=hub
#   MESH_TYPE=request|response|notification|alert|ack
#   MESH_SUBJECT=...
#   MESH_BODY=...
#   MESH_CORRELATION_ID=...
#   MESH_REPLY_URL=...
#   MESH_REPLY_TOKEN=...
#   MESH_PRIORITY=high|normal|low
#   MESH_TTL=300
#   MESH_EXPIRED=true|false
#   MESH_ATTACHMENT_COUNT=0
#   MESH_SIGNED=true|false
#   MESH_SIGNATURE_VALID=true|false|unchecked
#   MESH_REPLAY_SAFE=true|false|unchecked
#   MESH_REPLY_CONTEXT=<json>    (opaque routing context - echo back in response)
#
# Security features (opt-in):
#   - HMAC-SHA256 signature verification (requires signing key)
#   - Replay protection via nonce + timestamp window (default: 5 min)
#   - TTL-based message expiry
#
# Can also be sourced: source mesh-receive.sh && parse_mesh "$message"

set -euo pipefail

# Config
MESH_HOME="${MESH_HOME:-$HOME/.mesh}"
MESH_REPLAY_WINDOW="${MESH_REPLAY_WINDOW:-300}"  # 5 minutes default
MESH_NONCE_FILE="${MESH_HOME}/state/seen-nonces.log"

# ── Signature verification ──

_get_signing_key_for() {
    local sender="$1"
    local keyfile="$MESH_HOME/config/signing-keys/${sender}.key"
    if [[ -f "$keyfile" ]]; then
        cat "$keyfile" | tr -d '[:space:]'
    else
        echo ""
    fi
}

verify_signature() {
    local envelope="$1"
    local sender="$2"

    local received_sig
    received_sig=$(echo "$envelope" | jq -r '.signature // ""')

    if [[ -z "$received_sig" || "$received_sig" == "null" ]]; then
        echo "unsigned"
        return 0
    fi

    local key
    key=$(_get_signing_key_for "$sender")
    if [[ -z "$key" ]]; then
        echo "no_key"
        return 0
    fi

    # Strip the signature field from envelope before verifying
    # (signature was computed on the envelope without the signature field)
    local envelope_without_sig
    envelope_without_sig=$(echo "$envelope" | jq -c 'del(.signature)')

    # Extract the hash from "sha256:BASE64"
    local sig_data="${received_sig#sha256:}"

    # Compute expected signature
    local expected
    expected=$(echo -n "$envelope_without_sig" | openssl dgst -sha256 -hmac "$key" -binary 2>/dev/null | openssl base64 -A)

    if [[ "$expected" == "$sig_data" ]]; then
        echo "valid"
    else
        echo "invalid"
    fi
}

# ── Replay protection ──

check_replay() {
    local nonce="$1"
    local timestamp="$2"

    # Check timestamp is within window
    local now_epoch msg_epoch
    now_epoch=$(date +%s)
    msg_epoch=$(date -d "$timestamp" +%s 2>/dev/null || echo 0)

    if [[ $msg_epoch -eq 0 ]]; then
        echo "bad_timestamp"
        return 0
    fi

    local age=$(( now_epoch - msg_epoch ))
    if [[ $age -gt $MESH_REPLAY_WINDOW ]]; then
        echo "expired"
        return 0
    fi

    if [[ $age -lt -60 ]]; then
        # Message from >1min in the future - clock skew or replay
        echo "future"
        return 0
    fi

    # Check nonce hasn't been seen
    if [[ -z "$nonce" || "$nonce" == "null" ]]; then
        echo "no_nonce"
        return 0
    fi

    mkdir -p "$(dirname "$MESH_NONCE_FILE")"

    if grep -qF "$nonce" "$MESH_NONCE_FILE" 2>/dev/null; then
        echo "replay"
        return 0
    fi

    # Record nonce (with timestamp for cleanup)
    echo "${now_epoch}:${nonce}" >> "$MESH_NONCE_FILE"

    # Cleanup old nonces (older than 2x replay window)
    local cutoff=$(( now_epoch - MESH_REPLAY_WINDOW * 2 ))
    if [[ -f "$MESH_NONCE_FILE" ]]; then
        local tmp
        tmp=$(mktemp)
        awk -F: -v cutoff="$cutoff" '$1 >= cutoff' "$MESH_NONCE_FILE" > "$tmp" 2>/dev/null || true
        mv "$tmp" "$MESH_NONCE_FILE"
    fi

    echo "safe"
}

# ── Parse envelope ──

parse_mesh() {
    local msg="$1"
    
    # Try to detect MESH envelope
    if echo "$msg" | jq -e '.protocol' >/dev/null 2>&1; then
        local proto
        proto=$(echo "$msg" | jq -r '.protocol // ""')
        
        if [[ "$proto" == "mesh/1.0" || "$proto" == "sfiac/1.0" ]]; then
            echo "MESH_DETECTED=true"
            
            local from_agent
            from_agent=$(echo "$msg" | jq -r '.from // ""')
            
            echo "MESH_ID=$(echo "$msg" | jq -r '.id // ""')"
            echo "MESH_FROM=$from_agent"
            echo "MESH_TO=$(echo "$msg" | jq -r '.to // ""')"
            echo "MESH_TYPE=$(echo "$msg" | jq -r '.type // ""')"
            echo "MESH_SUBJECT=$(echo "$msg" | jq -r '.payload.subject // ""')"
            echo "MESH_BODY=$(echo "$msg" | jq -r '.payload.body // ""')"
            echo "MESH_CORRELATION_ID=$(echo "$msg" | jq -r '.correlationId // ""')"
            echo "MESH_REPLY_URL=$(echo "$msg" | jq -r '.replyTo.url // ""')"
            echo "MESH_REPLY_TOKEN=$(echo "$msg" | jq -r '.replyTo.token // ""')"
            echo "MESH_REPLY_CONTEXT=$(echo "$msg" | jq -c '.replyContext // null')"
            echo "MESH_PRIORITY=$(echo "$msg" | jq -r '.priority // "normal"')"
            echo "MESH_TTL=$(echo "$msg" | jq -r '.ttl // 300')"
            echo "MESH_ATTACHMENT_COUNT=$(echo "$msg" | jq -r '.payload.attachments | length // 0')"
            
            # Check expiry (TTL)
            local ts ttl now_epoch msg_epoch
            ts=$(echo "$msg" | jq -r '.timestamp // ""')
            ttl=$(echo "$msg" | jq -r '.ttl // 300')
            now_epoch=$(date +%s)
            msg_epoch=$(date -d "$ts" +%s 2>/dev/null || echo 0)
            
            if [[ $msg_epoch -gt 0 && $((msg_epoch + ttl)) -lt $now_epoch ]]; then
                echo "MESH_EXPIRED=true"
            else
                echo "MESH_EXPIRED=false"
            fi
            
            # Signature verification
            local has_sig
            has_sig=$(echo "$msg" | jq -r '.signature // ""')
            if [[ -n "$has_sig" && "$has_sig" != "null" ]]; then
                echo "MESH_SIGNED=true"
                local sig_result
                sig_result=$(verify_signature "$msg" "$from_agent")
                case "$sig_result" in
                    valid)   echo "MESH_SIGNATURE_VALID=true" ;;
                    invalid) echo "MESH_SIGNATURE_VALID=false" ;;
                    no_key)  echo "MESH_SIGNATURE_VALID=unchecked" ;;
                esac
            else
                echo "MESH_SIGNED=false"
                echo "MESH_SIGNATURE_VALID=unchecked"
            fi
            
            # Replay protection
            local nonce
            nonce=$(echo "$msg" | jq -r '.nonce // ""')
            if [[ -n "$nonce" && "$nonce" != "null" ]]; then
                local replay_result
                replay_result=$(check_replay "$nonce" "$ts")
                case "$replay_result" in
                    safe)       echo "MESH_REPLAY_SAFE=true" ;;
                    replay)     echo "MESH_REPLAY_SAFE=false" ;;
                    expired)    echo "MESH_REPLAY_SAFE=false" ;;
                    future)     echo "MESH_REPLAY_SAFE=false" ;;
                    *)          echo "MESH_REPLAY_SAFE=unchecked" ;;
                esac
            else
                echo "MESH_REPLAY_SAFE=unchecked"
            fi
            
            return 0
        fi
    fi
    
    echo "MESH_DETECTED=false"
    return 1
}

# Build a MESH response envelope
# Sign a MESH envelope with HMAC-SHA256
_mesh_sign_envelope() {
    local envelope="$1"
    local target_agent="$2"
    local my_name="${3:-$MESH_AGENT}"

    local keyfile="$MESH_HOME/config/signing-keys/${target_agent}.key"
    if [[ ! -f "$keyfile" ]]; then
        keyfile="$MESH_HOME/config/signing-keys/${my_name}.key"
    fi

    if [[ ! -f "$keyfile" ]]; then
        echo "$envelope"  # Return unsigned if no key found
        return
    fi

    local key signature
    key=$(cat "$keyfile")
    signature=$(echo -n "$envelope" | openssl dgst -sha256 -hmac "$key" -binary | base64)
    echo "$envelope" | jq -c --arg sig "$signature" '. + {signature: $sig}'
}

build_mesh_response() {
    local original_msg="$1"
    local response_body="$2"
    local response_subject="${3:-Response}"
    local my_name="${4:-$MESH_AGENT}"
    
    local orig_id orig_from
    orig_id=$(echo "$original_msg" | jq -r '.id')
    orig_from=$(echo "$original_msg" | jq -r '.from')
    
    # Preserve replyContext - echo it back untouched for delivery routing
    local reply_context
    reply_context=$(echo "$original_msg" | jq -c '.replyContext // null')
    
    local resp_id="msg_$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)"
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
    
    local _unsigned_env
    _unsigned_env=$(jq -n -c \
        --arg protocol "mesh/1.0" \
        --arg id "$resp_id" \
        --arg ts "$timestamp" \
        --arg from "$my_name" \
        --arg to "$orig_from" \
        --arg correlationId "$orig_id" \
        --argjson replyContext "$reply_context" \
        --arg subject "$response_subject" \
        --arg body "$response_body" \
        '{
            protocol: $protocol,
            id: $id,
            timestamp: $ts,
            from: $from,
            to: $to,
            type: "response",
            correlationId: $correlationId,
            replyContext: $replyContext,
            payload: {
                subject: $subject,
                body: $body
            }
        }')

    # Sign the response envelope
    _mesh_sign_envelope "$_unsigned_env" "$orig_from" "$my_name"
}

# Send a MESH response back using replyTo from original message
send_mesh_response() {
    local original_msg="$1"
    local response_body="$2"
    local response_subject="${3:-Response}"
    local my_name="${4:-$MESH_AGENT}"
    
    local reply_url reply_token
    reply_url=$(echo "$original_msg" | jq -r '.replyTo.url // ""')
    reply_token=$(echo "$original_msg" | jq -r '.replyTo.token // ""')
    
    if [[ -z "$reply_url" || "$reply_url" == "null" ]]; then
        echo "ERROR: No replyTo URL in original message" >&2
        return 1
    fi
    
    local envelope
    envelope=$(build_mesh_response "$original_msg" "$response_body" "$response_subject" "$my_name")
    
    # Extract sessionKey from replyContext for direct session routing
    # If present, OpenClaw will route the response directly to the originating session
    local session_key
    session_key=$(echo "$original_msg" | jq -r '.replyContext.sessionKey // empty' 2>/dev/null || true)
    
    local post_body
    if [[ -n "$session_key" ]]; then
        post_body=$(jq -n -c \
            --arg message "$envelope" \
            --arg sessionKey "$session_key" \
            '{message: $message, sessionKey: $sessionKey}')
    else
        post_body=$(jq -n -c \
            --arg message "$envelope" \
            '{message: $message}')
    fi
    
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 10 \
        --max-time 30 \
        -X POST "$reply_url" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${reply_token}" \
        -d "$post_body" 2>/dev/null || echo "000")
    
    if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        echo "OK"
        return 0
    else
        echo "FAIL:${http_code}" >&2
        return 1
    fi
}

# If called directly (not sourced), parse the argument
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ $# -lt 1 ]]; then
        echo "Usage: mesh-receive.sh '<json_message>'"
        echo "  Or: source mesh-receive.sh && parse_mesh \"\$msg\""
        exit 1
    fi
    parse_mesh "$1"
fi

# --- MESH v3: Conversation tracking ---

# Update conversation state when a response arrives
# Called when a MESH response is received with a conversationId
update_conversation_state() {
    local conv_id="$1"
    local from_agent="$2"
    local response_body="$3"
    local response_ts="${4:-$(date -u +%Y-%m-%dT%H:%M:%S.000Z)}"
    
    local conv_dir="${MESH_HOME:-$HOME/clawd/openclaw-mesh}/state/conversations"
    local conv_file="$conv_dir/${conv_id}.json"
    
    [[ -f "$conv_file" ]] || return 0  # No state file = not a tracked conversation
    
    # Add response and increment counter
    local summary
    summary=$(echo "$response_body" | head -c 200)
    
    jq --arg from "$from_agent" \
       --arg body "$summary" \
       --arg ts "$response_ts" \
       '.receivedResponses += 1 |
        .responses += [{"from": $from, "summary": $body, "ts": $ts}] |
        .updatedAt = $ts |
        if .receivedResponses >= .expectedResponses then .status = "complete" else . end' \
       "$conv_file" > "${conv_file}.tmp" && mv "${conv_file}.tmp" "$conv_file"
    
    # Check if conversation is now complete
    local status
    status=$(jq -r '.status' "$conv_file")
    local received
    received=$(jq -r '.receivedResponses' "$conv_file")
    local expected
    expected=$(jq -r '.expectedResponses' "$conv_file")
    
    if [[ "$status" == "complete" ]]; then
        # Log completion to audit
        local audit_log="${MESH_HOME:-$HOME/clawd/openclaw-mesh}/logs/mesh-audit.jsonl"
        jq -n -c \
            --arg ts "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" \
            --arg conv "$conv_id" \
            --argjson received "$received" \
            --argjson expected "$expected" \
            '{ts:$ts, conversationId:$conv, type:"rally/complete", status:"complete", received:$received, expected:$expected}' \
            >> "$audit_log"
        
        echo "✅ Conversation $conv_id complete ($received/$expected responses)"
    else
        echo "📨 Conversation $conv_id: $received/$expected responses"
    fi
}

# Extract conversationId from a MESH message's replyContext
get_conversation_id() {
    local msg="$1"
    echo "$msg" | jq -r '.replyContext.conversationId // empty' 2>/dev/null
}
