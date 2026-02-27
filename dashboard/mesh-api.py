"""
MESH Protocol Dashboard API
Add this to your dashboard server.py for MESH monitoring.

Usage:
    from mesh_api import collect_mesh_data, MESH_DEFAULTS
    
    # In your HTTP handler:
    data = collect_mesh_data(
        audit_log="/path/to/mesh-audit.jsonl",
        state_dir="/path/to/state/",
        registry="/path/to/agent-registry.json"
    )
"""

import json
import os
import subprocess
from datetime import datetime, timezone, timedelta


def collect_mesh_data(audit_log=None, state_dir=None, registry=None, ssh_agents=False):
    """Collect MESH protocol stats for dashboard display.
    
    Args:
        audit_log: Path to mesh-audit.jsonl
        state_dir: Path to state/ directory
        registry: Path to agent-registry.json
        ssh_agents: If True, SSH to remote agents for their audit logs (slow)
    
    Returns:
        dict with messages, stats, circuitBreakers, deadLetters, incidents, registry
    """
    mesh_home = os.environ.get("MESH_HOME", os.path.expanduser("~/.mesh"))
    audit_log = audit_log or os.path.join(mesh_home, "logs", "mesh-audit.jsonl")
    state_dir = state_dir or os.path.join(mesh_home, "state")
    registry = registry or os.path.join(mesh_home, "config", "agent-registry.json")

    data = {
        "messages": [],
        "stats": {
            "totalSent": 0, "totalReceived": 0, "totalFailed": 0,
            "byAgent": {}, "byType": {}, "last24h": 0,
        },
        "circuitBreakers": {},
        "deadLetters": [],
        "incidents": [],
        "registry": {},
    }

    # Load registry
    try:
        with open(registry) as f:
            data["registry"] = json.load(f).get("agents", {})
    except Exception:
        pass

    # Load audit log
    try:
        messages = []
        with open(audit_log) as f:
            for line in f:
                line = line.strip()
                if line:
                    try:
                        messages.append(json.loads(line))
                    except json.JSONDecodeError:
                        pass
        messages = messages[-200:]
        data["messages"] = messages

        now = datetime.now(timezone.utc)
        day_ago = now - timedelta(hours=24)

        for msg in messages:
            status = msg.get("status", "unknown")
            msg_type = msg.get("type", "unknown")
            to_agent = msg.get("to", "unknown")

            if status == "sent":
                data["stats"]["totalSent"] += 1
            elif "error" in status or "fail" in status:
                data["stats"]["totalFailed"] += 1

            data["stats"]["byType"][msg_type] = data["stats"]["byType"].get(msg_type, 0) + 1

            if to_agent not in data["stats"]["byAgent"]:
                data["stats"]["byAgent"][to_agent] = {"sent": 0, "received": 0, "failed": 0}
            data["stats"]["byAgent"][to_agent]["sent"] += 1

            try:
                ts = datetime.fromisoformat(msg.get("ts", "").replace("Z", "+00:00"))
                if ts > day_ago:
                    data["stats"]["last24h"] += 1
            except (ValueError, TypeError):
                pass
    except FileNotFoundError:
        pass

    # Load state files
    for name, key in [("circuit-breakers.json", "circuitBreakers"),
                       ("dead-letters.json", "deadLetters"),
                       ("active-incidents.json", "incidents")]:
        try:
            with open(os.path.join(state_dir, name)) as f:
                content = json.load(f)
                if key == "deadLetters":
                    data[key] = content.get("messages", [])
                elif key == "incidents":
                    data[key] = content.get("incidents", [])
                else:
                    data[key] = content
        except Exception:
            pass

    return data
