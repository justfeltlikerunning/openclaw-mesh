#!/usr/bin/env python3
"""Generate shared context for MESH conversation follow-ups."""
import json, sys, os

conv_file = sys.argv[1] if len(sys.argv) > 1 else ""
if not conv_file or not os.path.exists(conv_file):
    sys.exit(0)  # No context = empty output

try:
    with open(conv_file) as f:
        conv = json.load(f)
    
    rounds = conv.get("rounds", [])
    if not rounds:
        sys.exit(0)
    
    lines = ["📋 CONVERSATION CONTEXT (prior rounds):"]
    lines.append(f"Conversation: {conv.get('conversationId', '?')}")
    lines.append(f"Participants: {', '.join(conv.get('participants', []))}")
    lines.append("")
    
    for i, r in enumerate(rounds, 1):
        lines.append(f"── Round {i} ({r.get('status', '?')}) ──")
        lines.append(f"Q: {r.get('question', '?')[:200]}")
        for resp in r.get("responses", []):
            agent = resp.get("agent", resp.get("from", "?"))
            body = resp.get("body", resp.get("summary", ""))[:300]
            lines.append(f"  {agent}: {body}")
        if not r.get("responses"):
            lines.append("  (no responses yet)")
        lines.append("")
    
    print("\n".join(lines))
except Exception as e:
    print(f"[context error: {e}]", file=sys.stderr)
    sys.exit(0)
