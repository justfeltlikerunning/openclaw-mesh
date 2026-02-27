#!/usr/bin/env bash
# mesh-conv-search.sh - Search and replay MESH conversations
# Usage: mesh-conv-search.sh [options]
#
# Options:
#   --agent <name>      Filter by participant agent
#   --status <status>   Filter by status (active|complete|timeout|closed|cancelled)
#   --query <text>      Search question/response text
#   --since <date>      Filter by date (YYYY-MM-DD)
#   --type <type>       Filter by conversation type (rally|collab|escalation|broadcast)
#   --json              Output as JSON array
#   --limit <N>         Max results (default: 20)

set -euo pipefail

MESH_HOME="${MESH_HOME:-$HOME/clawd/openclaw-mesh}"
CONV_DIR="$MESH_HOME/state/conversations"
ARCHIVE_DIR="$MESH_HOME/state/conversations-archive"

AGENT=""
STATUS=""
QUERY=""
SINCE=""
CONV_TYPE=""
JSON_OUT=false
LIMIT=20

while [[ $# -gt 0 ]]; do
    case "$1" in
        --agent)  AGENT="$2"; shift 2 ;;
        --status) STATUS="$2"; shift 2 ;;
        --query)  QUERY="$2"; shift 2 ;;
        --since)  SINCE="$2"; shift 2 ;;
        --type)   CONV_TYPE="$2"; shift 2 ;;
        --json)   JSON_OUT=true; shift ;;
        --limit)  LIMIT="$2"; shift 2 ;;
        *)        shift ;;
    esac
done

export AGENT STATUS QUERY SINCE CONV_TYPE JSON_OUT LIMIT CONV_DIR ARCHIVE_DIR

python3 <<'PYEOF'
import json, os, glob, sys
from datetime import datetime

agent = os.environ.get('AGENT', '')
status_filter = os.environ.get('STATUS', '')
query = os.environ.get('QUERY', '').lower()
since = os.environ.get('SINCE', '')
conv_type = os.environ.get('CONV_TYPE', '')
json_out = os.environ.get('JSON_OUT', 'false') == 'true'
limit = int(os.environ.get('LIMIT', '20'))
conv_dir = os.environ['CONV_DIR']
archive_dir = os.environ.get('ARCHIVE_DIR', '')

# Collect all conversations (active + archived)
files = glob.glob(os.path.join(conv_dir, '*.json'))
archive_dir = os.environ.get('ARCHIVE_DIR', '')
if archive_dir:
    files += glob.glob(os.path.join(archive_dir, '*.json'))

results = []
for f in files:
    try:
        with open(f) as fh:
            conv = json.load(fh)
    except:
        continue
    
    # Apply filters
    if status_filter and conv.get('status') != status_filter:
        continue
    
    if agent:
        participants = conv.get('participants', [])
        if agent not in participants and conv.get('from') != agent:
            continue
    
    if conv_type and conv.get('type') != conv_type:
        continue
    
    if since:
        created = conv.get('createdAt', '')[:10]
        if created < since:
            continue
    
    if query:
        # Search in question, responses, and round questions
        searchable = conv.get('question', '').lower()
        for r in conv.get('rounds', []):
            searchable += ' ' + r.get('question', '').lower()
            for resp in r.get('responses', []):
                searchable += ' ' + resp.get('body', '').lower()
        for resp in conv.get('responses', []):
            searchable += ' ' + resp.get('body', '').lower()
        if query not in searchable:
            continue
    
    results.append(conv)

# Sort by createdAt descending
results.sort(key=lambda c: c.get('createdAt', ''), reverse=True)
results = results[:limit]

if json_out:
    print(json.dumps(results, indent=2))
else:
    if not results:
        print("No conversations found matching criteria.")
        sys.exit(0)
    
    status_icons = {
        'active': '🔵', 'pending': '⏳', 'partial': '📨',
        'complete': '✅', 'timeout': '⏰', 'closed': '🔒', 'cancelled': '🚫'
    }
    
    print(f"Found {len(results)} conversation(s):")
    print("---")
    for conv in results:
        cid = conv.get('conversationId', '?')
        st = conv.get('status', '?')
        icon = status_icons.get(st, '❓')
        participants = ', '.join(conv.get('participants', []))
        question = conv.get('question', '')[:80]
        rounds = len(conv.get('rounds', []))
        created = conv.get('createdAt', '?')[:16]
        
        round_info = f" [{rounds} rounds]" if rounds > 1 else ""
        print(f"{icon} {cid} ({st}){round_info}")
        print(f"   {created} | {conv.get('from', '?')} → {participants}")
        print(f"   Q: {question}")
        print()
PYEOF
