#!/bin/bash
# mesh-brain-sync.sh - Push MESH audit logs to a centralized knowledge base
# Run periodically (cron) to keep the Brain updated on inter-agent MESH conversations
# Tracks last sync position to only push new entries

set -euo pipefail

MESH_HOME="${MESH_HOME:-$HOME/openclaw-mesh}"
BRAIN_URL="${BRAIN_URL:-http://localhost:8900}"
AUDIT_LOG="$MESH_HOME/logs/mesh-audit.jsonl"
SYNC_STATE="$MESH_HOME/state/brain-sync-offset"

# Read last sync position
OFFSET=0
[[ -f "$SYNC_STATE" ]] && OFFSET=$(cat "$SYNC_STATE")

# Count total lines
TOTAL=$(wc -l < "$AUDIT_LOG" 2>/dev/null || echo 0)

if [[ $TOTAL -le $OFFSET ]]; then
    exit 0  # Nothing new
fi

# Process new entries
NEW_COUNT=0
tail -n +$((OFFSET + 1)) "$AUDIT_LOG" | while IFS= read -r line; do
    # Parse the audit entry
    FROM=$(echo "$line" | jq -r '.from // "?"')
    TO=$(echo "$line" | jq -r '.to // "?"')
    TYPE=$(echo "$line" | jq -r '.type // "?"')
    SUBJECT=$(echo "$line" | jq -r '.subject // ""')
    BODY=$(echo "$line" | jq -r '.body // ""')
    TS=$(echo "$line" | jq -r '.ts // ""')
    STATUS=$(echo "$line" | jq -r '.status // ""')
    CORR=$(echo "$line" | jq -r '.correlationId // ""')

    # Format for Brain ingestion
    TEXT="MESH ${TYPE} at ${TS}: ${FROM} → ${TO} [${STATUS}]. ${BODY:-$SUBJECT}"
    [ -n "$CORR" ] && TEXT="$TEXT (correlation: $CORR)"

    # Push to Brain
    curl -s -X POST "$BRAIN_URL/ingest" \
        -H "Content-Type: application/json" \
        -d "$(jq -n -c --arg text "$TEXT" --arg agent "mesh-${FROM}" --arg source "mesh-audit" \
            '{text: $text, agent: $agent, source_file: $source}')" >/dev/null 2>&1

    NEW_COUNT=$((NEW_COUNT + 1))
done

# Update sync position
echo "$TOTAL" > "$SYNC_STATE"
echo "Synced $((TOTAL - OFFSET)) new MESH entries to Brain"
