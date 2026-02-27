#!/usr/bin/env bash
# mesh-conversation.sh - MESH v3 Conversation Lifecycle Manager (Phase 5)
# Usage: mesh-conversation.sh <command> [args]
#   list                          - Show conversations (default: active only)
#   list --all                    - Show all conversations including closed
#   show <conv_id>                - Show full conversation detail with rounds
#   complete <conv_id> [summary]  - Mark conversation as complete
#   close <conv_id> [reason]      - Close/resolve a conversation
#   cancel <conv_id> [reason]     - Cancel an active conversation
#   timeout                       - Auto-timeout expired conversations
#   cleanup [--days N]            - Archive old completed conversations (default: 7 days)
#   consensus <conv_id> [--round N] - Analyze response consensus
#   search [--agent X --status Y]   - Search conversations
#   stats                         - Conversation statistics

set -euo pipefail

MESH_HOME="${MESH_HOME:-$HOME/clawd/openclaw-mesh}"
CONV_DIR="$MESH_HOME/state/conversations"
ARCHIVE_DIR="$MESH_HOME/state/conversations-archive"
AUDIT_LOG="$MESH_HOME/logs/mesh-audit.jsonl"
mkdir -p "$CONV_DIR" "$ARCHIVE_DIR"

NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
NOW_EPOCH=$(date +%s)

CMD="${1:-list}"
shift || true

_log_audit() {
    local type="$1" conv_id="$2" extra="${3:-}"
    local entry
    entry=$(jq -n -c --arg ts "$NOW_ISO" --arg conv "$conv_id" --arg type "$type" \
        '{ts:$ts, conversationId:$conv, type:$type}')
    [[ -n "$extra" ]] && entry=$(echo "$entry" | jq -c ". + $extra")
    echo "$entry" >> "$AUDIT_LOG"
}

_status_icon() {
    case "$1" in
        active)     echo "🔵" ;;
        pending)    echo "⏳" ;;
        partial)    echo "📨" ;;
        complete)   echo "✅" ;;
        timeout)    echo "⏰" ;;
        closed)     echo "🔒" ;;
        cancelled)  echo "🚫" ;;
        *)          echo "❓" ;;
    esac
}

case "$CMD" in
    list)
        SHOW_ALL=false
        [[ "${1:-}" == "--all" ]] && SHOW_ALL=true
        
        echo "📋 Conversations:"
        echo "---"
        found=0
        for f in "$CONV_DIR"/*.json; do
            [[ -f "$f" ]] || continue
            status=$(jq -r '.status' "$f")
            
            # Skip closed/cancelled unless --all
            if [[ "$SHOW_ALL" == false && ("$status" == "closed" || "$status" == "cancelled") ]]; then
                continue
            fi
            
            found=1
            conv_id=$(jq -r '.conversationId' "$f")
            from=$(jq -r '.from' "$f")
            participants=$(jq -r '.participants | join(",")' "$f")
            question=$(jq -r '.question | .[0:80]' "$f")
            created=$(jq -r '.createdAt' "$f")
            rounds=$(jq '.rounds | length // 0' "$f" 2>/dev/null || echo 0)
            current_round=$(jq '.currentRound // 1' "$f")
            icon=$(_status_icon "$status")
            
            # Round status summary
            round_info=""
            if [[ "$rounds" -gt 1 ]]; then
                round_info=" [${rounds} rounds]"
            fi
            
            echo "$icon $conv_id ($status)${round_info}"
            echo "   From: $from → $participants"
            echo "   Q: $question"
            echo "   Created: $created"
            echo ""
        done
        [[ $found -eq 0 ]] && echo "  (no conversations found)"
        ;;
        
    show)
        CONV_ID="${1:-}"
        [[ -z "$CONV_ID" ]] && { echo "Usage: mesh-conversation.sh show <conv_id>"; exit 1; }
        CONV_FILE="$CONV_DIR/${CONV_ID}.json"
        [[ -f "$CONV_FILE" ]] || { echo "Conversation not found: $CONV_ID"; exit 1; }
        
        # Pretty-print conversation with rounds
        python3 -c "
import json
with open('$CONV_FILE') as f:
    conv = json.load(f)

cid = conv.get('conversationId', '?')
status = conv.get('status', '?')
created = conv.get('createdAt', '?')
updated = conv.get('updatedAt', '')
from_agent = conv.get('from', '?')
participants = ', '.join(conv.get('participants', []))

print(f'📨 Conversation: {cid}')
print(f'   Status: {status} | From: {from_agent} → {participants}')
print(f'   Created: {created}')
if updated: print(f'   Updated: {updated}')
if conv.get('summary'): print(f'   Summary: {conv[\"summary\"]}')
if conv.get('closedReason'): print(f'   Closed: {conv[\"closedReason\"]}')
print()

rounds = conv.get('rounds', [])
if not rounds:
    # Legacy: show flat responses
    print('── Responses ──')
    for r in conv.get('responses', []):
        agent = r.get('agent', r.get('from', '?'))
        body = r.get('body', r.get('summary', ''))[:200]
        print(f'  {agent}: {body}')
else:
    for r in rounds:
        rnum = r.get('round', '?')
        rstatus = r.get('status', '?')
        rq = r.get('question', '?')[:150]
        print(f'── Round {rnum} ({rstatus}) ──')
        print(f'   Q: {rq}')
        for resp in r.get('responses', []):
            agent = resp.get('agent', resp.get('from', '?'))
            body = resp.get('body', resp.get('summary', ''))[:200]
            ts = resp.get('ts', '')
            print(f'   ├── {agent}: {body}')
        if not r.get('responses'):
            print('   (no responses yet)')
        print()
"
        echo "📜 Related audit entries:"
        grep "$CONV_ID" "$AUDIT_LOG" 2>/dev/null | jq -c '{ts, from, to, type, round: .round, subject: (.subject // "" | .[0:60])}' 2>/dev/null | tail -20 || echo "  (none)"
        ;;
        
    complete)
        CONV_ID="${1:-}"
        SUMMARY="${2:-Completed}"
        [[ -z "$CONV_ID" ]] && { echo "Usage: mesh-conversation.sh complete <conv_id> [summary]"; exit 1; }
        CONV_FILE="$CONV_DIR/${CONV_ID}.json"
        [[ -f "$CONV_FILE" ]] || { echo "Conversation not found: $CONV_ID"; exit 1; }
        
        jq --arg status "complete" --arg summary "$SUMMARY" --arg ts "$NOW_ISO" \
            '.status = $status | .summary = $summary | .completedAt = $ts | .updatedAt = $ts' \
            "$CONV_FILE" > "${CONV_FILE}.tmp" && mv "${CONV_FILE}.tmp" "$CONV_FILE"
        
        # Also complete current round
        jq --arg ts "$NOW_ISO" \
            'if .rounds then .rounds[-1].status = "complete" else . end | .updatedAt = $ts' \
            "$CONV_FILE" > "${CONV_FILE}.tmp" && mv "${CONV_FILE}.tmp" "$CONV_FILE"
        
        _log_audit "rally/complete" "$CONV_ID" "$(jq -n -c --arg s "$SUMMARY" '{summary:$s, status:"complete"}')"
        echo "✅ Conversation $CONV_ID marked complete: $SUMMARY"
        ;;
    
    close)
        CONV_ID="${1:-}"
        REASON="${2:-Resolved}"
        [[ -z "$CONV_ID" ]] && { echo "Usage: mesh-conversation.sh close <conv_id> [reason]"; exit 1; }
        CONV_FILE="$CONV_DIR/${CONV_ID}.json"
        [[ -f "$CONV_FILE" ]] || { echo "Conversation not found: $CONV_ID"; exit 1; }
        
        jq --arg status "closed" --arg reason "$REASON" --arg ts "$NOW_ISO" \
            '.status = $status | .closedReason = $reason | .closedAt = $ts | .updatedAt = $ts' \
            "$CONV_FILE" > "${CONV_FILE}.tmp" && mv "${CONV_FILE}.tmp" "$CONV_FILE"
        
        _log_audit "conversation/closed" "$CONV_ID" "$(jq -n -c --arg r "$REASON" '{reason:$r}')"
        echo "🔒 Conversation $CONV_ID closed: $REASON"
        ;;
    
    cancel)
        CONV_ID="${1:-}"
        REASON="${2:-Cancelled}"
        [[ -z "$CONV_ID" ]] && { echo "Usage: mesh-conversation.sh cancel <conv_id> [reason]"; exit 1; }
        CONV_FILE="$CONV_DIR/${CONV_ID}.json"
        [[ -f "$CONV_FILE" ]] || { echo "Conversation not found: $CONV_ID"; exit 1; }
        
        jq --arg status "cancelled" --arg reason "$REASON" --arg ts "$NOW_ISO" \
            '.status = $status | .cancelledReason = $reason | .cancelledAt = $ts | .updatedAt = $ts' \
            "$CONV_FILE" > "${CONV_FILE}.tmp" && mv "${CONV_FILE}.tmp" "$CONV_FILE"
        
        _log_audit "conversation/cancelled" "$CONV_ID" "$(jq -n -c --arg r "$REASON" '{reason:$r}')"
        echo "🚫 Conversation $CONV_ID cancelled: $REASON"
        ;;
        
    timeout)
        expired=0
        for f in "$CONV_DIR"/*.json; do
            [[ -f "$f" ]] || continue
            status=$(jq -r '.status' "$f")
            [[ "$status" == "closed" || "$status" == "cancelled" || "$status" == "complete" || "$status" == "timeout" ]] && continue
            
            expires_at=$(jq -r '.expiresAt // empty' "$f")
            if [[ -n "$expires_at" ]]; then
                expires_epoch=$(date -d "$expires_at" +%s 2>/dev/null || echo 999999999999)
                if [[ $NOW_EPOCH -gt $expires_epoch ]]; then
                    conv_id=$(jq -r '.conversationId' "$f")
                    jq --arg ts "$NOW_ISO" \
                        '.status = "timeout" | .updatedAt = $ts | .timedOutAt = $ts' \
                        "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
                    _log_audit "conversation/timeout" "$conv_id" '{"status":"timeout"}'
                    echo "⏰ Timed out: $conv_id"
                    expired=$((expired + 1))
                fi
            else
                # Fallback: use createdAt + ttl
                created=$(jq -r '.createdAt' "$f")
                ttl=$(jq -r '.ttl // 300' "$f")
                created_epoch=$(date -d "$created" +%s 2>/dev/null || echo 0)
                age=$(( NOW_EPOCH - created_epoch ))
                if [[ $age -gt $ttl ]]; then
                    conv_id=$(jq -r '.conversationId' "$f")
                    jq --arg ts "$NOW_ISO" \
                        '.status = "timeout" | .updatedAt = $ts | .timedOutAt = $ts' \
                        "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
                    _log_audit "conversation/timeout" "$conv_id" '{"status":"timeout"}'
                    echo "⏰ Timed out: $conv_id (age: ${age}s > ttl: ${ttl}s)"
                    expired=$((expired + 1))
                fi
            fi
        done
        [[ $expired -eq 0 ]] && echo "No expired conversations."
        ;;
    
    cleanup)
        DAYS=7
        [[ "${1:-}" == "--days" ]] && DAYS="${2:-7}"
        CUTOFF_EPOCH=$(( NOW_EPOCH - DAYS * 86400 ))
        archived=0
        
        for f in "$CONV_DIR"/*.json; do
            [[ -f "$f" ]] || continue
            status=$(jq -r '.status' "$f")
            [[ "$status" != "complete" && "$status" != "timeout" && "$status" != "closed" && "$status" != "cancelled" ]] && continue
            
            updated=$(jq -r '.updatedAt // .createdAt' "$f")
            updated_epoch=$(date -d "$updated" +%s 2>/dev/null || echo 999999999999)
            
            if [[ $updated_epoch -lt $CUTOFF_EPOCH ]]; then
                conv_id=$(jq -r '.conversationId' "$f")
                mv "$f" "$ARCHIVE_DIR/"
                echo "📦 Archived: $conv_id ($status, updated: $updated)"
                archived=$((archived + 1))
            fi
        done
        echo "Archived $archived conversations (older than ${DAYS} days)."
        ;;
    
    stats)
        total=0 active=0 complete=0 timeout=0 closed=0 cancelled=0 pending=0
        total_rounds=0 max_rounds=0
        
        for f in "$CONV_DIR"/*.json; do
            [[ -f "$f" ]] || continue
            total=$((total + 1))
            s=$(jq -r '.status' "$f")
            rounds=$(jq '.rounds | length // 0' "$f" 2>/dev/null || echo 0)
            total_rounds=$((total_rounds + rounds))
            [[ $rounds -gt $max_rounds ]] && max_rounds=$rounds
            
            case "$s" in
                active|partial) active=$((active + 1)) ;;
                pending) pending=$((pending + 1)) ;;
                complete) complete=$((complete + 1)) ;;
                timeout) timeout=$((timeout + 1)) ;;
                closed) closed=$((closed + 1)) ;;
                cancelled) cancelled=$((cancelled + 1)) ;;
            esac
        done
        
        archived=$(ls "$ARCHIVE_DIR"/*.json 2>/dev/null | wc -l || echo 0)
        avg_rounds=0
        [[ $total -gt 0 ]] && avg_rounds=$(echo "scale=1; $total_rounds / $total" | bc)
        
        echo "📊 Conversation Statistics"
        echo "---"
        echo "  Total:     $total active + $archived archived"
        echo "  🔵 Active:  $active"
        echo "  ⏳ Pending: $pending"
        echo "  ✅ Complete: $complete"
        echo "  ⏰ Timeout: $timeout"
        echo "  🔒 Closed:  $closed"
        echo "  🚫 Cancelled: $cancelled"
        echo "  📊 Rounds:  $total_rounds total, max $max_rounds, avg $avg_rounds"
        ;;
        
    consensus)
        CONV_ID="${1:-}"
        [[ -z "$CONV_ID" ]] && { echo "Usage: mesh-conversation.sh consensus <conv_id> [--round N]"; exit 1; }
        shift
        # Delegate to mesh-consensus.sh
        if [ -n "${BASH_SOURCE[0]:-}" ]; then
            _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        else
            _SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
        fi
        exec bash "$_SCRIPT_DIR/mesh-consensus.sh" "$CONV_ID" "$@"
        ;;
    
    search)
        shift 2>/dev/null || true
        if [ -n "${BASH_SOURCE[0]:-}" ]; then
            _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        else
            _SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
        fi
        exec bash "$_SCRIPT_DIR/mesh-conv-search.sh" "$@"
        ;;
    
    *)
        echo "Usage: mesh-conversation.sh <command> [args]"
        echo ""
        echo "Commands:"
        echo "  list [--all]              Show conversations"
        echo "  show <conv_id>            Show conversation detail with rounds"
        echo "  complete <conv_id> [msg]  Mark complete with summary"
        echo "  close <conv_id> [reason]  Close/resolve conversation"
        echo "  cancel <conv_id> [reason] Cancel active conversation"
        echo "  consensus <conv_id>       Analyze consensus (--round N)"
        echo "  search [filters]          Search conversations (--agent, --status, --query)"
        echo "  timeout                   Auto-timeout expired conversations"
        echo "  cleanup [--days N]        Archive old conversations"
        echo "  stats                     Show statistics"
        exit 1
        ;;
esac

