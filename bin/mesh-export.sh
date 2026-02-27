#!/usr/bin/env bash
# mesh-export.sh - Export audit logs for analysis
#
# Usage:
#   mesh-export.sh                            # All messages, JSON
#   mesh-export.sh --csv                      # CSV format
#   mesh-export.sh --from agent-a               # Filter by sender
#   mesh-export.sh --to agent-b                # Filter by recipient
#   mesh-export.sh --since 24h                # Last 24 hours
#   mesh-export.sh --since 7d                 # Last 7 days
#   mesh-export.sh --type request             # Filter by type
#   mesh-export.sh --status sent              # Filter by status
#   mesh-export.sh --from agent-a --to agent-b --since 24h --csv

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

AUDIT_LOG="$MESH_HOME/logs/mesh-audit.jsonl"
FORMAT="json"
FILTER_FROM=""
FILTER_TO=""
FILTER_TYPE=""
FILTER_STATUS=""
SINCE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --csv)     FORMAT="csv"; shift ;;
        --json)    FORMAT="json"; shift ;;
        --from)    FILTER_FROM="$2"; shift 2 ;;
        --to)      FILTER_TO="$2"; shift 2 ;;
        --type)    FILTER_TYPE="$2"; shift 2 ;;
        --status)  FILTER_STATUS="$2"; shift 2 ;;
        --since)   SINCE="$2"; shift 2 ;;
        --help)
            echo "Usage: mesh-export.sh [--csv] [--from agent] [--to agent] [--type type] [--status status] [--since 24h|7d]"
            exit 0
            ;;
        *) shift ;;
    esac
done

# Compute since timestamp
SINCE_EPOCH=0
if [[ -n "$SINCE" ]]; then
    case "$SINCE" in
        *h) SINCE_EPOCH=$(($(date +%s) - ${SINCE%h} * 3600)) ;;
        *d) SINCE_EPOCH=$(($(date +%s) - ${SINCE%d} * 86400)) ;;
        *m) SINCE_EPOCH=$(($(date +%s) - ${SINCE%m} * 60)) ;;
        *)  SINCE_EPOCH=$(($(date +%s) - ${SINCE} )) ;;
    esac
fi

# Build jq filter
JQ_FILTER='.'
[[ -n "$FILTER_FROM" ]] && JQ_FILTER="$JQ_FILTER | select(.from == \"$FILTER_FROM\")"
[[ -n "$FILTER_TO" ]] && JQ_FILTER="$JQ_FILTER | select(.to == \"$FILTER_TO\")"
[[ -n "$FILTER_TYPE" ]] && JQ_FILTER="$JQ_FILTER | select(.type == \"$FILTER_TYPE\")"
[[ -n "$FILTER_STATUS" ]] && JQ_FILTER="$JQ_FILTER | select(.status == \"$FILTER_STATUS\")"

if [[ "$SINCE_EPOCH" -gt 0 ]]; then
    SINCE_ISO=$(date -u -d "@$SINCE_EPOCH" +"%Y-%m-%dT%H:%M:%S" 2>/dev/null || date -u -r "$SINCE_EPOCH" +"%Y-%m-%dT%H:%M:%S" 2>/dev/null)
    JQ_FILTER="$JQ_FILTER | select(.ts >= \"$SINCE_ISO\" or .timestamp >= \"$SINCE_ISO\")"
fi

if [[ "$FORMAT" == "csv" ]]; then
    echo "timestamp,from,to,type,status,subject,signed"
    jq -r "$JQ_FILTER | [(.ts // .timestamp // \"\"), (.from // \"\"), (.to // \"\"), (.type // \"\"), (.status // \"\"), (.subject // \"\" | gsub(\",\"; \";\")), (.signed // false | tostring)] | @csv" "$AUDIT_LOG" 2>/dev/null
else
    jq -c "$JQ_FILTER" "$AUDIT_LOG" 2>/dev/null
fi
