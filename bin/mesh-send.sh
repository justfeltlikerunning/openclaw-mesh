#!/usr/bin/env bash
# mesh-send.sh - Message Envelope for Structured Handoffs sender
# Usage: mesh-send.sh <agent|all> <type> "<message>" [options]
#
# Types: request, response, notification, alert, ack
#
# Options:
#   --wait <seconds>          Wait for response (request type only)
#   --priority <level>        high|normal|low (default: normal)
#   --ttl <seconds>           Time-to-live (default: 300)
#   --idempotency-key <key>   For dedup
#   --correlation-id <id>     Link response to original request
#   --subject <text>          One-line summary (default: auto-generated)
#   --attachment <url>        Attach URL (or url|mimeType|description)
#   --file <path>             Attach local file (auto base64 if <64KB, HTTP serve if larger)
#   --inline <base64>         Attach inline base64 data
#   --metadata <json>         Additional metadata JSON
#   --reply-context <json>    Opaque context to echo back in response (for routing replies)
#   --session <json>          Session tracking: {"key":"...","label":"...","user":"..."}
#   --session-key <key>       Shorthand: set session key only
#   --dry-run                 Print envelope without sending
#   --no-retry                Skip retry logic
#
# Examples:
#   mesh-send.sh worker-a request "How many tanks in Zone 5?"
#   mesh-send.sh worker-a request "Count active wells" --wait 120
#   mesh-send.sh all notification "Schema v2.3 deployed"
#   mesh-send.sh worker-d alert "Worker-A service down" --idempotency-key "worker-a-down-20260221"
#   mesh-send.sh worker-a response "47 tanks" --correlation-id "msg_abc123"

set -euo pipefail

# Resolve script directory - handle cron environments where BASH_SOURCE may be empty
if [ -n "${BASH_SOURCE[0]:-}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
elif [ -n "${0:-}" ] && [ "$0" != "bash" ] && [ "$0" != "-bash" ] && [ "$0" != "sh" ]; then
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
else
    SCRIPT_DIR=""
fi

# MESH_HOME can be set externally, or auto-detected from script location
# Supports: MESH_HOME/bin/mesh-send.sh (project layout)
#           MESH_HOME/scripts/mesh-send.sh (legacy clawd layout)
if [ -z "${MESH_HOME:-}" ]; then
    if [ -n "$SCRIPT_DIR" ]; then
        parent="$(dirname "$SCRIPT_DIR")"
        if [ -f "$parent/config/agent-registry.json" ]; then
            MESH_HOME="$parent"
        elif [ -f "$parent/../config/agent-registry.json" ]; then
            MESH_HOME="$(dirname "$parent")"
        else
            MESH_HOME="$parent"
        fi
    elif [ -f "$HOME/openclaw-mesh/config/agent-registry.json" ]; then
        # Fallback: common install location
        MESH_HOME="$HOME/openclaw-mesh"
    else
        echo "ERROR: Cannot determine MESH_HOME. Set MESH_HOME env var or run from a proper shell." >&2
        exit 1
    fi
fi

REGISTRY="${MESH_REGISTRY:-$MESH_HOME/config/agent-registry.json}"
CIRCUIT_FILE="$MESH_HOME/state/circuit-breakers.json"
DEAD_LETTER_FILE="$MESH_HOME/state/dead-letters.json"
AUDIT_LOG="$MESH_HOME/logs/mesh-audit.jsonl"

# Agent identity - set via MESH_AGENT env var or config file
if [ -n "${MESH_AGENT:-}" ]; then
    MY_AGENT="$MESH_AGENT"
elif [ -f "$MESH_HOME/config/identity" ]; then
    MY_AGENT="$(cat "$MESH_HOME/config/identity" | tr -d '[:space:]')"
else
    MY_AGENT="${USER:-unknown}"
fi

# Defaults
PRIORITY="normal"
TTL=300
CORRELATION_ID=""
CONVERSATION_ID=""
IDEMPOTENCY_KEY=""
SUBJECT=""
ATTACHMENTS=()
METADATA="{}"
REPLY_CONTEXT=""
SESSION_INFO=""
DRY_RUN=false
NO_RETRY=false
ENCRYPT=false
WAIT_SECONDS=0
FILE_SERVER_PID=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

usage() {
    echo "Usage: mesh-send.sh <agent|all> <type> \"<message>\" [options]"
    echo ""
    echo "Types: request, response, notification, alert, ack"
    echo ""
    echo "Options:"
    echo "  --wait <seconds>          Wait for response (request only)"
    echo "  --priority <level>        high|normal|low (default: normal)"
    echo "  --ttl <seconds>           Time-to-live (default: 300)"
    echo "  --idempotency-key <key>   For dedup"
    echo "  --correlation-id <id>     Link to original request"
    echo "  --subject <text>          One-line summary"
    echo "  --attachment <url>        Attach URL (or url|mimeType|desc)"
    echo "  --file <path>             Attach local file (auto inline/serve)"
    echo "  --inline <base64>         Attach inline base64 data"
    echo "  --metadata <json>         Additional metadata"
    echo "  --reply-context <json>    Opaque delivery context (echoed in response)"
    echo "  --dry-run                 Print envelope, don't send"
    echo "  --encrypt                 Encrypt payload body (AES-256-CBC)"
    echo "  --no-retry                Skip retry logic"
    exit 1
}

# ── Argument parsing ──

[[ $# -lt 3 ]] && usage

TARGET="$1"
MSG_TYPE="$2"
MSG_BODY="$3"
shift 3

while [[ $# -gt 0 ]]; do
    case "$1" in
        --wait)           WAIT_SECONDS="$2"; shift 2 ;;
        --priority)       PRIORITY="$2"; shift 2 ;;
        --ttl)            TTL="$2"; shift 2 ;;
        --correlation-id) CORRELATION_ID="$2"; shift 2 ;;
        --conversation-id) CONVERSATION_ID="$2"; shift 2 ;;
        --idempotency-key) IDEMPOTENCY_KEY="$2"; shift 2 ;;
        --subject)        SUBJECT="$2"; shift 2 ;;
        --attachment)     ATTACHMENTS+=("$2"); shift 2 ;;
        --file)           ATTACHMENTS+=("file:$2"); shift 2 ;;
        --inline)         ATTACHMENTS+=("inline:$2"); shift 2 ;;
        --metadata)       METADATA="$2"; shift 2 ;;
        --reply-context)  REPLY_CONTEXT="$2"; shift 2 ;;
        --session)        SESSION_INFO="$2"; shift 2 ;;
        --session-key)    SESSION_INFO="{\"key\":\"$2\"}"; shift 2 ;;
        --encrypt)        ENCRYPT=true; shift ;;
        --dry-run)        DRY_RUN=true; shift ;;
        --no-retry)       NO_RETRY=true; shift ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

# Validate type
case "$MSG_TYPE" in
    request|response|notification|alert|ack) ;;
    *) echo -e "${RED}Invalid type: $MSG_TYPE${NC}"; usage ;;
esac

# ── Helper functions ──

generate_msg_id() {
    echo "msg_$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)"
}

get_timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%S.000Z"
}

get_agent_info() {
    local agent="$1"
    jq -r ".agents.${agent}" "$REGISTRY"
}

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

# ── Signing (opt-in per agent) ──

is_signing_enabled() {
    local agent="$1"
    local enabled
    enabled=$(jq -r ".agents.${agent}.signing // false" "$REGISTRY" 2>/dev/null || echo "false")
    [[ "$enabled" == "true" ]]
}

get_signing_key() {
    # Signing key shared between this agent and the target
    # Stored in config/signing-keys/<agent>.key or MESH_HOME/config/signing-keys/<MY_AGENT>.key
    local agent="$1"
    local keyfile="$MESH_HOME/config/signing-keys/${agent}.key"
    if [[ -f "$keyfile" ]]; then
        cat "$keyfile" | tr -d '[:space:]'
    else
        echo ""
    fi
}

generate_nonce() {
    openssl rand -hex 16 2>/dev/null || cat /proc/sys/kernel/random/uuid | tr -d '-'
}

sign_envelope() {
    local envelope="$1"
    local key="$2"
    # HMAC-SHA256 of the envelope JSON
    echo -n "$envelope" | openssl dgst -sha256 -hmac "$key" -binary 2>/dev/null | openssl base64 -A
}

# ── Circuit breaker ──

check_circuit() {
    local agent="$1"
    local state
    state=$(jq -r ".${agent}.state // \"closed\"" "$CIRCUIT_FILE" 2>/dev/null || echo "closed")

    if [[ "$state" == "open" ]]; then
        local open_until
        open_until=$(jq -r ".${agent}.openUntil // \"\"" "$CIRCUIT_FILE" 2>/dev/null || echo "")
        if [[ -n "$open_until" ]]; then
            local now_epoch
            local until_epoch
            now_epoch=$(date +%s)
            until_epoch=$(date -d "$open_until" +%s 2>/dev/null || echo 0)
            if [[ $now_epoch -lt $until_epoch ]]; then
                echo "open"
                return
            else
                # Move to half-open
                update_circuit "$agent" "half-open" "" ""
                echo "half-open"
                return
            fi
        fi
    fi
    echo "$state"
}

update_circuit() {
    local agent="$1"
    local state="$2"
    local failures="$3"
    local open_until="$4"

    local tmp
    tmp=$(mktemp)

    if [[ -n "$failures" ]]; then
        jq ".${agent}.state = \"${state}\" | .${agent}.failures = ${failures} | .${agent}.openUntil = ${open_until:-null}" \
            "$CIRCUIT_FILE" > "$tmp"
    else
        jq ".${agent}.state = \"${state}\"" "$CIRCUIT_FILE" > "$tmp"
    fi
    mv "$tmp" "$CIRCUIT_FILE"
}

record_failure() {
    local agent="$1"
    local current_failures
    current_failures=$(jq -r ".${agent}.failures // 0" "$CIRCUIT_FILE" 2>/dev/null || echo 0)
    local new_failures=$((current_failures + 1))
    local now
    now=$(get_timestamp)

    if [[ $new_failures -ge 3 ]]; then
        local open_until
        open_until=$(date -u -d "+60 seconds" +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%S.000Z")
        local tmp
        tmp=$(mktemp)
        jq ".${agent}.state = \"open\" | .${agent}.failures = ${new_failures} | .${agent}.lastFailure = \"${now}\" | .${agent}.openUntil = \"${open_until}\"" \
            "$CIRCUIT_FILE" > "$tmp"
        mv "$tmp" "$CIRCUIT_FILE"
        echo -e "${RED}Circuit OPEN for ${agent} (${new_failures} failures). Cooldown until ${open_until}${NC}" >&2
    else
        local tmp
        tmp=$(mktemp)
        jq ".${agent}.failures = ${new_failures} | .${agent}.lastFailure = \"${now}\"" \
            "$CIRCUIT_FILE" > "$tmp"
        mv "$tmp" "$CIRCUIT_FILE"
    fi
}

record_success() {
    local agent="$1"
    update_circuit "$agent" "closed" "0" "null"
}

# ── Dead letter queue ──

write_dead_letter() {
    local agent="$1"
    local reason="$2"
    local attempts="$3"
    local envelope="$4"
    local now
    now=$(get_timestamp)

    # Max queue size - drop oldest if full (FIFO)
    local max_queue=${MESH_MAX_QUEUE:-100}
    local current_count
    current_count=$(jq '.messages | length' "$DEAD_LETTER_FILE" 2>/dev/null || echo 0)

    local tmp
    tmp=$(mktemp)
    if [[ $current_count -ge $max_queue ]]; then
        # Drop oldest message(s) to make room
        local drop=$((current_count - max_queue + 1))
        jq ".messages |= .[$drop:] | .messages += [{\"id\": $(echo "$envelope" | jq '.id'), \"timestamp\": \"${now}\", \"to\": \"${agent}\", \"failReason\": \"${reason}\", \"attempts\": ${attempts}, \"envelope\": ${envelope}}]" \
            "$DEAD_LETTER_FILE" > "$tmp"
        echo -e "${YELLOW}⚠ Queue at capacity (${max_queue}) - dropped ${drop} oldest message(s)${NC}" >&2
    else
        jq ".messages += [{\"id\": $(echo "$envelope" | jq '.id'), \"timestamp\": \"${now}\", \"to\": \"${agent}\", \"failReason\": \"${reason}\", \"attempts\": ${attempts}, \"envelope\": ${envelope}}]" \
            "$DEAD_LETTER_FILE" > "$tmp"
    fi
    mv "$tmp" "$DEAD_LETTER_FILE"
}

# ── Audit logging ──

audit_log() {
    local from="$1"
    local to="$2"
    local type="$3"
    local id="$4"
    local subject="$5"
    local status="$6"
    local correlation="${7:-}"
    local body="${8:-}"
    local now
    now=$(get_timestamp)

    # Extract extra fields from the envelope if available
    local reply_context=""
    local signature=""
    local nonce=""
    local session_data=""
    if [[ -n "${CURRENT_ENVELOPE:-}" ]]; then
        reply_context=$(echo "$CURRENT_ENVELOPE" | jq -r '.replyContext // empty' 2>/dev/null || true)
        signature=$(echo "$CURRENT_ENVELOPE" | jq -r '.signature // empty' 2>/dev/null || true)
        nonce=$(echo "$CURRENT_ENVELOPE" | jq -r '.nonce // empty' 2>/dev/null || true)
        session_data=$(echo "$CURRENT_ENVELOPE" | jq -c '.session // empty' 2>/dev/null || true)
    fi

    # Include conversationId if available (from CONVERSATION_ID var or replyContext)
    local conv_id="${CONVERSATION_ID:-}"
    if [[ -z "$conv_id" && -n "$reply_context" ]]; then
        conv_id=$(echo "$reply_context" | jq -r '.conversationId // empty' 2>/dev/null || true)
    fi

    local entry
    entry=$(jq -n -c \
        --arg ts "$now" \
        --arg from "$from" \
        --arg to "$to" \
        --arg type "$type" \
        --arg id "$id" \
        --arg subject "$subject" \
        --arg status "$status" \
        --arg corr "$correlation" \
        --arg conv "$conv_id" \
        --arg body "$body" \
        --arg replyContext "$reply_context" \
        --arg signature "$signature" \
        --arg nonce "$nonce" \
        --arg session "$session_data" \
        '{ts:$ts, from:$from, to:$to, type:$type, id:$id, subject:$subject, body:$body, status:$status, correlationId:$corr} + (if $conv != "" then {conversationId:$conv} else {} end) + (if $replyContext != "" then {replyContext:$replyContext} else {} end) + (if $signature != "" then {signed:true} else {signed:false} end) + (if $session != "" and $session != "null" then {session:($session | fromjson)} else {} end)')
    echo "$entry" >> "$AUDIT_LOG"
}

# ── Build envelope ──

build_envelope() {
    local agent="$1"
    local msg_id
    msg_id=$(generate_msg_id)
    local now
    now=$(get_timestamp)

    # Auto-generate subject if not provided
    local subject="$SUBJECT"
    if [[ -z "$subject" ]]; then
        subject=$(echo "$MSG_BODY" | head -c 80)
    fi

    # Build replyTo for request type
    local reply_to="null"
    if [[ "$MSG_TYPE" == "request" ]]; then
        local my_ip
        my_ip=$(get_agent_ip "$MY_AGENT")
        local my_port
        my_port=$(get_agent_port "$MY_AGENT")
        local my_token
        my_token=$(get_agent_token "$MY_AGENT")
        # If replyContext has sessionKey, use /hooks/agent endpoint for direct session routing
        # (mapped hooks like /hooks/<agent> ignore sessionKey from the POST body)
        local reply_hook_path="/hooks/${agent}"
        if [[ -n "$REPLY_CONTEXT" ]] && echo "$REPLY_CONTEXT" | jq -e '.sessionKey' > /dev/null 2>&1; then
            reply_hook_path="/hooks/agent"
        fi
        reply_to=$(jq -n -c \
            --arg url "http://${my_ip}:${my_port}${reply_hook_path}" \
            --arg token "$my_token" \
            '{url:$url, token:$token}')
    fi

    # Build attachments array
    local attachments="[]"
    if [[ ${#ATTACHMENTS[@]} -gt 0 ]]; then
        attachments="["
        local first=true
        for att in "${ATTACHMENTS[@]}"; do
            [[ "$first" == true ]] || attachments+=","
            first=false

            if [[ "$att" == file:* ]]; then
                # Local file - auto-detect type and serve or inline
                local filepath="${att#file:}"
                local filename
                filename=$(basename "$filepath")
                local filesize
                filesize=$(stat -c%s "$filepath" 2>/dev/null || echo 0)
                local mimetype
                mimetype=$(file -b --mime-type "$filepath" 2>/dev/null || echo "application/octet-stream")

                if [[ $filesize -lt 65536 ]]; then
                    # Small file - inline as base64
                    local b64data
                    b64data=$(base64 -w0 "$filepath")
                    attachments+=$(jq -n -c \
                        --arg type "inline" \
                        --arg encoding "base64" \
                        --arg data "$b64data" \
                        --arg filename "$filename" \
                        --arg mimeType "$mimetype" \
                        --argjson size "$filesize" \
                        '{type:$type, encoding:$encoding, data:$data, filename:$filename, mimeType:$mimeType, size:$size}')
                else
                    # Large file - serve via temp HTTP server
                    local serve_dir
                    serve_dir=$(dirname "$filepath")
                    local serve_port=8890

                    if [[ -z "$FILE_SERVER_PID" ]]; then
                        (cd "$serve_dir" && python3 -m http.server "$serve_port" >/dev/null 2>&1) &
                        FILE_SERVER_PID=$!
                        # Auto-cleanup after 5 minutes
                        (sleep 300 && kill "$FILE_SERVER_PID" 2>/dev/null) &
                        sleep 1  # Give server time to start
                    fi

                    local my_ip
                    my_ip=$(get_agent_ip "$MY_AGENT")
                    local file_url="http://${my_ip}:${serve_port}/${filename}"

                    attachments+=$(jq -n -c \
                        --arg type "url" \
                        --arg url "$file_url" \
                        --arg filename "$filename" \
                        --arg mimeType "$mimetype" \
                        --argjson size "$filesize" \
                        '{type:$type, url:$url, filename:$filename, mimeType:$mimeType, size:$size}')
                fi

            elif [[ "$att" == inline:* ]]; then
                # Explicit inline with base64 data
                local data="${att#inline:}"
                attachments+=$(jq -n -c \
                    --arg type "inline" \
                    --arg encoding "base64" \
                    --arg data "$data" \
                    '{type:$type, encoding:$encoding, data:$data}')

            elif [[ "$att" == *"|"* ]]; then
                # URL with pipe-separated metadata: url|mimeType|description
                IFS='|' read -r url mimetype desc <<< "$att"
                attachments+=$(jq -n -c \
                    --arg type "url" \
                    --arg url "$url" \
                    --arg mimeType "${mimetype:-application/octet-stream}" \
                    --arg description "${desc:-}" \
                    '{type:$type, url:$url, mimeType:$mimeType, description:$description}')
            else
                # Plain URL
                attachments+=$(jq -n -c --arg url "$att" '{type:"url", url:$url}')
            fi
        done
        attachments+="]"
    fi

    # Build correlation
    local corr_id="null"
    if [[ -n "$CORRELATION_ID" ]]; then
        corr_id="\"$CORRELATION_ID\""
    fi

    # Build idempotency key
    local idemp="null"
    if [[ -n "$IDEMPOTENCY_KEY" ]]; then
        idemp="\"$IDEMPOTENCY_KEY\""
    fi

    # Generate nonce for replay protection
    local nonce
    nonce=$(generate_nonce)

    # Build replyContext (opaque routing context for response delivery)
    local reply_context="null"
    if [[ -n "$REPLY_CONTEXT" ]]; then
        # Validate it's valid JSON
        if echo "$REPLY_CONTEXT" | jq . > /dev/null 2>&1; then
            reply_context="$REPLY_CONTEXT"
        else
            echo -e "${YELLOW}⚠ --reply-context is not valid JSON, wrapping as string${NC}" >&2
            reply_context=$(jq -n -c --arg v "$REPLY_CONTEXT" '$v')
        fi
    fi

    # Build session tracking (origin session info for end-to-end traceability)
    local session="null"
    if [[ -n "$SESSION_INFO" ]]; then
        if echo "$SESSION_INFO" | jq . > /dev/null 2>&1; then
            session="$SESSION_INFO"
        else
            session=$(jq -n -c --arg k "$SESSION_INFO" '{key:$k}')
        fi
    fi

    # Resolve conversationId - from flag, replyContext, or empty
    local conv_id_val="${CONVERSATION_ID:-}"
    if [[ -z "$conv_id_val" && "$reply_context" != "null" ]]; then
        conv_id_val=$(echo "$reply_context" | jq -r '.conversationId // empty' 2>/dev/null || true)
    fi
    local conv_id_json="null"
    [[ -n "$conv_id_val" ]] && conv_id_json="\"$conv_id_val\""

    # Build the envelope
    local envelope
    envelope=$(jq -n -c \
        --arg protocol "mesh/1.0" \
        --arg id "$msg_id" \
        --arg ts "$now" \
        --arg from "$MY_AGENT" \
        --arg to "$agent" \
        --arg type "$MSG_TYPE" \
        --argjson correlationId "$corr_id" \
        --argjson conversationId "$conv_id_json" \
        --argjson replyTo "$reply_to" \
        --argjson replyContext "$reply_context" \
        --arg priority "$PRIORITY" \
        --argjson ttl "$TTL" \
        --argjson idempotencyKey "$idemp" \
        --arg nonce "$nonce" \
        --arg subject "$subject" \
        --arg body "$MSG_BODY" \
        --argjson attachments "$attachments" \
        --argjson metadata "$METADATA" \
        --argjson session "$session" \
        '{
            protocol: $protocol,
            id: $id,
            timestamp: $ts,
            from: $from,
            to: $to,
            type: $type,
            correlationId: $correlationId,
            conversationId: $conversationId,
            replyTo: $replyTo,
            replyContext: $replyContext,
            session: $session,
            priority: $priority,
            ttl: $ttl,
            idempotencyKey: $idempotencyKey,
            nonce: $nonce,
            payload: {
                subject: $subject,
                body: $body,
                attachments: $attachments,
                metadata: $metadata
            }
        }')

    # Encrypt payload body if requested
    if $ENCRYPT; then
        local crypt_script="$MESH_HOME/bin/mesh-crypt.sh"
        if [[ -x "$crypt_script" ]]; then
            local encrypted_body
            encrypted_body=$("$crypt_script" encrypt "$agent" "$MSG_BODY" 2>/dev/null)
            if [[ $? -eq 0 && -n "$encrypted_body" ]]; then
                envelope=$(echo "$envelope" | jq -c --argjson enc "$encrypted_body" '.payload.body = ($enc | tostring) | .payload.encrypted = true')
            else
                echo -e "${YELLOW}⚠ Encryption failed - sending plaintext${NC}" >&2
            fi
        else
            echo -e "${YELLOW}⚠ mesh-crypt.sh not found - sending plaintext${NC}" >&2
        fi
    fi

    # Sign if enabled for target agent
    if is_signing_enabled "$agent"; then
        local signing_key
        signing_key=$(get_signing_key "$agent")
        if [[ -n "$signing_key" ]]; then
            local sig
            sig=$(sign_envelope "$envelope" "$signing_key")
            # Inject signature into envelope
            envelope=$(echo "$envelope" | jq -c --arg sig "sha256:${sig}" '. + {signature: $sig}')
        else
            echo -e "${YELLOW}⚠ Signing enabled for ${agent} but no key found at config/signing-keys/${agent}.key${NC}" >&2
        fi
    fi

    echo "$envelope"
}

# ── Send with retry ──

send_to_agent() {
    local agent="$1"
    local envelope="$2"
    
    # Make envelope available for audit_log to extract extra fields
    CURRENT_ENVELOPE="$envelope"

    local ip port token
    ip=$(get_agent_ip "$agent")
    port=$(get_agent_port "$agent")
    token=$(get_agent_token "$agent")

    if [[ "$ip" == "null" || -z "$ip" ]]; then
        echo -e "${RED}Unknown agent: ${agent}${NC}" >&2
        return 1
    fi

    # Check circuit breaker
    local circuit_state
    circuit_state=$(check_circuit "$agent")
    if [[ "$circuit_state" == "open" ]]; then
        echo -e "${RED}Circuit OPEN for ${agent} - message queued to dead letters${NC}" >&2
        write_dead_letter "$agent" "circuit_open" 0 "$envelope"
        audit_log "$MY_AGENT" "$agent" "$MSG_TYPE" "$(echo "$envelope" | jq -r '.id')" "$(echo "$envelope" | jq -r '.payload.subject')" "circuit_open" "" "$(echo "$envelope" | jq -r '.payload.body // ""')"
        return 1
    fi

    # Determine hook URL: use /hooks/agent when replyContext has sessionKey
    # (mapped hooks like /hooks/<agent> ignore sessionKey from the POST body)
    local session_key
    session_key=$(echo "$envelope" | jq -r '.replyContext.sessionKey // empty' 2>/dev/null || true)
    
    # OpenClaw's dispatchAgentHook prepends "agent:<agentId>:" to the sessionKey,
    # so we must strip that prefix if present to avoid double-prefixing
    # e.g., "agent:main:signal:direct:+1234" → "signal:direct:+1234"
    if [[ "$session_key" =~ ^agent:[^:]+: ]]; then
        session_key=$(echo "$session_key" | sed 's/^agent:[^:]*://')
    fi
    
    local url
    if [[ -n "$session_key" ]]; then
        url="http://${ip}:${port}/hooks/agent"
    else
        url="http://${ip}:${port}/hooks/${MY_AGENT}"
    fi
    
    local msg_id
    msg_id=$(echo "$envelope" | jq -r '.id')
    local subject
    subject=$(echo "$envelope" | jq -r '.payload.subject')
    local body
    body=$(echo "$envelope" | jq -r '.payload.body // ""')

    # Wrap envelope in hook payload
    # sessionKey already extracted above for URL routing
    
    local hook_payload
    if [[ -n "$session_key" ]]; then
        hook_payload=$(jq -n -c \
            --arg message "$envelope" \
            --arg sessionKey "$session_key" \
            '{message: $message, sessionKey: $sessionKey}')
    else
        hook_payload=$(jq -n -c --arg message "$envelope" '{message: $message}')
    fi

    # Build signature header if present
    local sig_header_name=""
    local sig_header_value=""
    local envelope_sig
    envelope_sig=$(echo "$envelope" | jq -r '.signature // ""')
    if [[ -n "$envelope_sig" ]]; then
        sig_header_name="-H"
        sig_header_value="X-MESH-Signature: ${envelope_sig}"
    fi

    # Retry loop
    local retries=4
    local delays=(0 5 15 60)
    local attempt=0

    if [[ "$NO_RETRY" == true ]]; then
        retries=1
        delays=(0)
    fi

    while [[ $attempt -lt $retries ]]; do
        local delay=${delays[$attempt]}
        if [[ $delay -gt 0 ]]; then
            echo -e "${YELLOW}Retry ${attempt}/${retries} - waiting ${delay}s...${NC}" >&2
            sleep "$delay"
        fi

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
            record_success "$agent"
            audit_log "$MY_AGENT" "$agent" "$MSG_TYPE" "$msg_id" "$subject" "sent" "" "$body"
            
            # If this is a response with a conversationId, notify the target's dashboard
            local resp_conv_id
            resp_conv_id=$(echo "$envelope" | jq -r '.conversationId // .replyContext.conversationId // .meta.conversationId // empty' 2>/dev/null)
            if [[ "$MSG_TYPE" == "response" && -n "$resp_conv_id" ]]; then
                local dash_ip
                dash_ip=$(get_agent_ip "$agent")
                # Notify target's dashboard API for real-time conversation state update
                curl -s -o /dev/null --connect-timeout 2 --max-time 3 \
                    -X POST "http://${dash_ip}:8880/api/mesh/response" \
                    -H "Content-Type: application/json" \
                    -d "{\"conversationId\":\"$resp_conv_id\",\"from\":\"$MY_AGENT\",\"body\":$(echo "$body" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()[:500]))' 2>/dev/null || echo '""'),\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\"}" 2>/dev/null || true
            fi
            
            # Auto-record to collaborative session if session key present
            # Skip if session-router already recorded (prevents duplicates)
            if [[ -z "${_MESH_SESSION_ALREADY_RECORDED:-}" ]]; then
                local session_key_val
                session_key_val=$(echo "$envelope" | jq -r '.session.key // empty' 2>/dev/null)
                if [[ -n "$session_key_val" ]]; then
                    local sr="$MESH_HOME/bin/mesh-session-router.sh"
                    if [[ -x "$sr" ]]; then
                        "$sr" receive "$envelope" > /dev/null 2>&1 || true
                    fi
                fi
            fi
            
            echo -e "${GREEN}✓ Sent to ${agent} (HTTP ${http_code}) - ${msg_id}${NC}" >&2
            echo "$msg_id"
            return 0
        elif [[ "$http_code" =~ ^4[0-9][0-9]$ ]]; then
            # Client error - don't retry
            record_failure "$agent"
            audit_log "$MY_AGENT" "$agent" "$MSG_TYPE" "$msg_id" "$subject" "client_error_${http_code}" "" "$body"
            echo -e "${RED}✗ Client error from ${agent} (HTTP ${http_code}) - not retrying${NC}" >&2
            write_dead_letter "$agent" "client_error_${http_code}" "$((attempt + 1))" "$envelope"
            return 1
        else
            echo -e "${YELLOW}✗ Failed to reach ${agent} (HTTP ${http_code}) - attempt $((attempt + 1))/${retries}${NC}" >&2
        fi

        attempt=$((attempt + 1))
    done

    # All retries exhausted - try relay routing if available
    local routing_table="$MESH_HOME/state/routing-table.json"
    if [[ -f "$routing_table" ]]; then
        local relay
        relay=$(jq -r '.relay // empty' "$routing_table")
        if [[ -n "$relay" && "$relay" != "$agent" && "$relay" != "$MY_AGENT" ]]; then
            echo -e "${YELLOW}Attempting relay via ${relay}...${NC}" >&2
            
            # Wrap the original envelope in a relay envelope
            local relay_ip relay_port relay_token
            relay_ip=$(get_agent_ip "$relay")
            relay_port=$(get_agent_port "$relay")
            relay_token=$(get_agent_token "$relay")
            
            if [[ "$relay_ip" != "null" && -n "$relay_ip" ]]; then
                # Add relay header to envelope
                local relayed_envelope
                relayed_envelope=$(echo "$envelope" | jq -c --arg relay "$MY_AGENT" --arg via "$relay" \
                    '. + {relay: {from: $relay, via: $via, originalTo: .to}}')
                
                local relay_payload
                relay_payload=$(jq -n -c --arg message "$relayed_envelope" '{message: $message}')
                
                local relay_code
                relay_code=$(curl -s -o /dev/null -w "%{http_code}" \
                    --connect-timeout 10 --max-time 30 \
                    -X POST "http://${relay_ip}:${relay_port}/hooks/${MY_AGENT}" \
                    -H "Content-Type: application/json" \
                    -H "Authorization: Bearer ${relay_token}" \
                    -d "$relay_payload" 2>/dev/null || echo "000")
                
                if [[ "$relay_code" =~ ^2[0-9][0-9]$ ]]; then
                    record_success "$agent"
                    audit_log "$MY_AGENT" "$agent" "$MSG_TYPE" "$msg_id" "$subject" "relayed_via_${relay}" "" "$body"
                    echo -e "${GREEN}✓ Relayed to ${agent} via ${relay} (HTTP ${relay_code}) - ${msg_id}${NC}" >&2
                    echo "$msg_id"
                    return 0
                fi
                echo -e "${RED}✗ Relay via ${relay} also failed (HTTP ${relay_code})${NC}" >&2
            fi
        fi
    fi
    
    record_failure "$agent"
    audit_log "$MY_AGENT" "$agent" "$MSG_TYPE" "$msg_id" "$subject" "failed_all_retries" "" "$body"
    write_dead_letter "$agent" "all_retries_exhausted" "$retries" "$envelope"
    echo -e "${RED}✗ All ${retries} attempts failed for ${agent} - written to dead letters${NC}" >&2
    return 1
}

# ── Main ──

# Get list of target agents
if [[ "$TARGET" == "all" ]]; then
    AGENTS=$(jq -r --arg me "$MY_AGENT" '.agents | keys[] | select(. != $me)' "$REGISTRY")
else
    AGENTS="$TARGET"
fi

RESULTS=""
EXIT_CODE=0

for agent in $AGENTS; do
    envelope=$(build_envelope "$agent")

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${BLUE}[DRY RUN] Envelope for ${agent}:${NC}"
        echo "$envelope" | jq .
        continue
    fi

    msg_id=$(send_to_agent "$agent" "$envelope") || {
        EXIT_CODE=1
        continue
    }

    # If --wait specified for request type, poll for response
    if [[ "$MSG_TYPE" == "request" && $WAIT_SECONDS -gt 0 ]]; then
        echo -e "${BLUE}Waiting up to ${WAIT_SECONDS}s for response from ${agent}...${NC}" >&2
        # Response will come back via hook - check audit log for correlating response
        local end_time=$(($(date +%s) + WAIT_SECONDS))
        while [[ $(date +%s) -lt $end_time ]]; do
            # Check if a response with our correlation ID appeared in the audit log
            if grep -q "\"correlationId\":\"${msg_id}\"" "$AUDIT_LOG" 2>/dev/null; then
                echo -e "${GREEN}✓ Response received for ${msg_id}${NC}" >&2
                grep "\"correlationId\":\"${msg_id}\"" "$AUDIT_LOG" | tail -1
                break
            fi
            sleep 2
        done
    fi
done

exit $EXIT_CODE
