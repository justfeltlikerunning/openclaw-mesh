# MESH v3 - Conversation Threading

## Problem Statement

MESH v2 is message-level: fire a message, maybe get a response via correlationId. No concept of multi-message conversations. This causes:

1. **Rally fragmentation** - sending the same question to 2 agents = 2 separate audit entries, no grouping
2. **No shared context** - if Agent A and Agent B both answer, neither sees the other's response
3. **Follow-ups fork** - a follow-up to Agent A doesn't carry Agent B's context
4. **Dashboard noise** - flat list of messages with no threading, hard to trace question→answers→resolution
5. **No conversation lifecycle** - no way to mark a conversation as resolved/complete

## Core Concept: Conversations

A **conversation** is a group of related MESH messages with a shared `conversationId`. All messages (requests, responses, follow-ups, notifications) within a conversation carry this ID.

### Conversation Types

| Type | Description | Example |
|------|-------------|---------|
| `rally` | One question to N agents, collect responses | Cross-check query |
| `collab` | Multi-turn discussion between agents | Schema investigation |
| `escalation` | Issue flows up the trust hierarchy | Agent-D → Agent-C → Coordinator |
| `broadcast` | One-way notification to all/subset | Schema correction |

## Protocol Changes

### New Envelope Fields

```json
{
  "protocol": "mesh/3.0",
  "id": "msg_xxx",
  "conversationId": "conv_abc123",      // NEW - groups messages into conversations
  "conversationSeq": 3,                  // NEW - message sequence within conversation
  "participants": ["agent-a", "agent-b"],    // NEW - all agents in this conversation
  "parentMessageId": "msg_yyy",          // NEW - what message this replies to (threading)
  "rally": {                             // NEW - rally-specific metadata
    "question": "Count active records...",
    "expectedResponses": 2,
    "receivedResponses": 1,
    "status": "pending"                  // pending | complete | timeout
  },
  // Existing fields
  "from": "coordinator",
  "to": "agent-a",
  "type": "request",
  "body": "...",
  "replyTo": { "url": "...", "token": "..." },
  "correlationId": "msg_yyy",
  "signature": "...",
  "ttl": 300
}
```

### Rally Flow (v3)

```
Coordinator                    Agent-A                   Agent-B
  |                        |                       |
  |-- rally/open --------->|                       |
  |     conv_abc123        |                       |
  |-- rally/open ------------------------------->>|
  |     conv_abc123                                |
  |                        |                       |
  |<--- response ----------|                       |
  |     conv_abc123, seq=2 |                       |
  |     "1,250 tanks"      |                       |
  |                        |                       |
  |<--- response ----------------------------------|
  |     conv_abc123, seq=3                         |
  |     "1,250 tanks"                              |
  |                                                |
  |-- rally/complete -->                           |
  |     conv_abc123                                |
  |     summary: "Match ✅"                        |
```

### Shared Context (the big win)

When a response arrives, the conversation state is updated. Follow-up messages include a `context` field with prior responses:

```json
{
  "conversationId": "conv_abc123",
  "context": {
    "originalQuestion": "Count active records in 0V134",
    "responses": [
      {"from": "agent-a", "summary": "1,250", "ts": "..."},
      {"from": "agent-b", "summary": "1,250", "ts": "..."}
    ]
  },
  "body": "Both match. Now count injection points for the same district."
}
```

Agent receiving the follow-up sees what everyone else said. No more blind forks.

## Audit Log Changes

### Current (v2) - flat entries
```jsonl
{"from":"coordinator","to":"agent-a","type":"request","id":"msg_1",...}
{"from":"coordinator","to":"agent-b","type":"request","id":"msg_2",...}
{"from":"agent-a","to":"coordinator","type":"response","id":"msg_3","correlationId":"msg_1",...}
{"from":"agent-b","to":"coordinator","type":"response","id":"msg_4","correlationId":"msg_2",...}
```

### v3 - conversation-aware
```jsonl
{"conversationId":"conv_abc","type":"rally/open","participants":["agent-a","agent-b"],"question":"Count active records..."}
{"conversationId":"conv_abc","from":"agent-a","type":"response","seq":2,"body":"1,250"}
{"conversationId":"conv_abc","from":"agent-b","type":"response","seq":3,"body":"1,250"}
{"conversationId":"conv_abc","type":"rally/complete","summary":"Match ✅ 0% discrepancy"}
```

## Dashboard MESH Panel Changes

### Grouped View
Instead of flat message list:
```
📨 conv_abc - Rally to agent-a, agent-b (2m ago)
   "Count active records in 0V134"
   ├── 📊 agent-a: 1,250 (32s)
   ├── 📋 agent-b: 1,250 (45s)
   └── ✅ Complete - Match (0% discrepancy)

📨 conv_def - Escalation: agent-d → agent-c → coordinator (15m ago)
   "Dashboard /api/brain returning stale data"
   ├── 🔧 agent-d: "Service API last_updated is 2h old"
   ├── ⚡ agent-c: "Agent-e gateway OOMd, restarting..."
   ├── 🐊 agent-c: "Agent-E back online, service re-indexing"
   └── ✅ Resolved
```

### Filters
- Filter by: conversation type (rally/collab/escalation/broadcast)
- Filter by: status (active/complete/timeout)
- Filter by: participants
- Expand/collapse conversation threads

## Implementation Plan

### Phase 1 - Conversation IDs (foundation)
- [ ] Add `conversationId` generation to `mesh-rally.sh`
- [ ] Add `conversationId` and `participants` to MESH envelope in `mesh-send.sh`
- [ ] Update `mesh-audit.jsonl` format to include conversation fields
- [ ] Update audit log parser in dashboard `server.py`
- [ ] Backward compatible - messages without `conversationId` render as before

### Phase 2 - Rally Tracking
- [ ] Rally state file: `~/openclaw-mesh/state/conversations/<conv_id>.json`
- [ ] Track expected vs received responses
- [ ] Auto-complete when all responses received or TTL expires
- [ ] Summary generation (match/mismatch/timeout)

### Phase 3 - Dashboard Threading
- [ ] Group messages by `conversationId` in MESH panel
- [ ] Collapsible conversation threads
- [ ] Status badges (pending/complete/timeout)
- [ ] Response time display per agent
- [ ] Comparison view for rally responses

### Phase 4 - Shared Context
- [ ] Context accumulation in conversation state file
- [ ] Follow-up messages include prior responses
- [ ] Agents receive shared context in hook template
- [ ] Conversation history available via API

### Phase 5 - Conversation Lifecycle
- [ ] Open/active/complete/timeout/cancelled states
- [ ] Auto-timeout conversations after TTL
- [ ] Manual close via `mesh-conversation.sh close <conv_id>`
- [ ] Conversation search and replay

## Backward Compatibility

- v2 messages (no `conversationId`) render as standalone entries (current behavior)
- v3 agents can talk to v2 agents - the conversation fields are additive
- Dashboard supports both: threaded view for v3, flat view for v2
- Rollout: update `mesh-rally.sh` first (biggest win), then `mesh-send.sh`

## Files to Modify

| File | Change |
|------|--------|
| `mesh-send.sh` | Add conversationId, participants, parentMessageId |
| `mesh-rally.sh` | Generate conversationId, track responses, auto-complete |
| `mesh-receive.sh` | Parse conversation fields, update state |
| `mesh-audit.jsonl` | Include conversation fields in log entries |
| `dashboard/server.py` | Group audit entries by conversationId |
| `dashboard/index.html` | Threaded MESH panel with filters |
| NEW: `mesh-conversation.sh` | CLI for listing/closing/inspecting conversations |
| NEW: `state/conversations/` | Conversation state files |

## Non-Goals (v3)

- Real-time WebSocket streaming between agents (use SSE/polling)
- Agent-to-agent direct conversation without Coordinator routing (keep hub model)
- Encryption per-conversation (MESH v2 HMAC signing is sufficient)
- Chat-like UX in dashboard (it's a monitoring tool, not Slack)
