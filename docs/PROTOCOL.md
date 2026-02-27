# MESH Protocol - Message Envelope for Structured Handoffs

> **Version:** 1.0-draft
> **Author:** Hub
> **Date:** 2026-02-21
> **Status:** PROPOSAL - for review

---

## Executive Summary

Our current inter-agent communication is a brittle patchwork of HTTP hooks, curl callbacks embedded in natural language, and Slack channel reads. It works *sometimes*. It also:

- Fails silently when agents don't execute embedded curl commands
- Confuses callback URLs (wrong IP, wrong token - happened multiple times)
- Has no delivery confirmation, no retry, no timeout handling
- Relies on `allowUnsafeExternalContent: true` which bypasses prompt injection safety
- Generates massive alert floods during outages (Feb 21: 40+ duplicate alerts from one incident)
- Has no message deduplication or idempotency

This document proposes a layered protocol that fixes all of this while staying within OpenClaw's existing primitives - no external message bus needed.

---

## Table of Contents

1. [Current State & Pain Points](#1-current-state--pain-points)
2. [Design Principles](#2-design-principles)
3. [Architecture Overview](#3-architecture-overview)
4. [Layer 1: Transport (HTTP Hooks)](#4-layer-1-transport-http-hooks)
5. [Layer 2: Message Envelope](#5-layer-2-message-envelope)
6. [Layer 3: Conversation Patterns](#6-layer-3-conversation-patterns)
7. [Layer 4: Orchestration](#7-layer-4-orchestration)
8. [Resilience & Failure Handling](#8-resilience--failure-handling)
9. [Alert Deduplication](#9-alert-deduplication)
10. [Security Model](#10-security-model)
11. [Migration Plan](#11-migration-plan)
12. [Future: Message Bus Option](#12-future-message-bus-option)

---

## 1. Current State & Pain Points

### What We Have

```
Agent A ──POST /hooks/<sender>──► Agent B's Gateway
         (HTTP 202 = accepted)

Agent B processes message in isolated hook session.
Agent B *might* curl back to Agent A's /hooks/<sender>.
Agent B *might* just respond in its own Slack channel.
Agent B *might* do nothing.
```

### Known Failures (from experience)

| Problem | Example | Impact |
|---------|---------|--------|
| **Agents don't execute embedded curl callbacks** | Rally pattern: 6 agents accepted messages, 0 curled back (Feb 19) | Complete loss of response |
| **Wrong callback URL/token** | Hub sent Worker-A's callback pointing to Worker-D's IP (Feb 19) | Response goes to wrong agent |
| **`deliver: true` is broken** | Mapped hooks with `deliver: true` never produce Slack output (Feb 20) | Silent failure |
| **No response confirmation** | HTTP 202 = "accepted" not "processed" | No way to know if agent actually handled it |
| **Alert storms** | 40+ Worker-D alerts for same outage in 6 hours (Feb 21) | Alert fatigue, wasted tokens |
| **Prompt injection risk** | `allowUnsafeExternalContent: true` on all inter-agent hooks | Trusted LAN, but still bad practice |
| **No message ordering** | Concurrent requests can interleave | Confused context |
| **No idempotency** | Same alert fires repeatedly, agent processes each as new | Duplicate work |

### Current Communication Map

```
Hub (Hub) ◄──────► Worker-A (DB)
     ▲ ▲                  ▲
     │ └──────► Worker-B ◄──┘
     │            ▲
     ├──────► Worker-C
     ├──────► Worker-D (SRE)
     ├──────► Worker-E (Brain)
     └──────► Worker-F (Church)

All links = HTTP POST to /hooks/<sender>
All responses = "maybe curl back, maybe Slack, maybe nothing"
```

---

## 2. Design Principles

1. **Use what works.** OpenClaw hooks are the transport. Don't replace them - standardize them.
2. **Structured > natural language.** JSON envelopes, not "hey, curl this back to me."
3. **Fire-and-forget is fine** for notifications. **Request-reply needs a contract.**
4. **Idempotent by default.** Every message gets an ID. Receivers dedup.
5. **Fail loud, not silent.** If delivery fails, the sender knows.
6. **Progressive enhancement.** Start with what we can deploy today, layer on message bus later.
7. **Minimize token burn.** Structured messages → less LLM interpretation needed.

---

## 3. Architecture Overview

```
┌─────────────────────────────────────────────────┐
│              Layer 4: ORCHESTRATION              │
│   (Hub hub, rally pattern, workflows)         │
├─────────────────────────────────────────────────┤
│           Layer 3: CONVERSATION PATTERNS         │
│   (fire-forget, request-reply, pub-sub, relay)   │
├─────────────────────────────────────────────────┤
│            Layer 2: MESSAGE ENVELOPE             │
│   (JSON schema, msg ID, correlation, routing)    │
├─────────────────────────────────────────────────┤
│            Layer 1: TRANSPORT                    │
│   (HTTP POST to OpenClaw /hooks/<path>)          │
└─────────────────────────────────────────────────┘
```

---

## 4. Layer 1: Transport (HTTP Hooks)

**No changes to the underlying mechanism.** We continue using OpenClaw's webhook system.

### Endpoint Convention

```
POST http://<agent_ip>:18789/hooks/<sender_name>
Authorization: Bearer <receiver_token>
Content-Type: application/json
```

### Health Probing

Each agent exposes its OpenClaw gateway health endpoint:

```
GET http://<agent_ip>:18789/health
→ 200 OK (with JSON body)
```

**Before sending a message to an agent, the sender SHOULD check health first** (unless the message is itself a health check or time-critical alert).

### Transport Guarantees

- **At-most-once delivery** (HTTP POST, no automatic retry at transport level)
- **202 Accepted** = gateway received the payload, NOT that the agent processed it
- **Connection timeout:** 10s (if agent unreachable, fail fast)
- **No TLS** (LAN-only, trusted network)

---

## 5. Layer 2: Message Envelope

**This is the core improvement.** Every inter-agent message MUST use this JSON envelope.

### Standard Envelope

```json
{
  "protocol": "mesh/1.0",
  "id": "msg_<uuid>",
  "timestamp": "2026-02-21T20:45:00.000Z",
  "from": "hub",
  "to": "worker-1",
  "type": "request|response|notification|alert|ack",
  "correlationId": null,
  "replyTo": {
    "url": "http://192.168.1.10:18789/hooks/worker-a",
    "token": "hub-hook-token"
  },
  "replyContext": null,
  "priority": "normal|high|low",
  "ttl": 300,
  "idempotencyKey": null,
  "payload": {
    "subject": "Short description for logging",
    "body": "The actual message/query for the agent",
    "attachments": [],
    "metadata": {}
  }
}
```

### Field Definitions

| Field | Required | Description |
|-------|----------|-------------|
| `protocol` | ✅ | Always `"mesh/1.0"` - identifies this as a structured inter-agent message |
| `id` | ✅ | Unique message ID (`msg_<uuid4>`) - for dedup and correlation |
| `timestamp` | ✅ | ISO 8601 UTC - when the message was created |
| `from` | ✅ | Sender agent name (lowercase, matches hook path names) |
| `to` | ✅ | Intended recipient agent name |
| `type` | ✅ | Message type (see below) |
| `correlationId` | ❌ | Links response to original request (set to original msg `id`) |
| `replyTo` | ❌ | Where to send the response (only for `request` type) |
| `replyContext` | ❌ | Opaque routing context echoed back in response for session routing (see §5.1) |
| `priority` | ❌ | Default `normal`. `high` = process immediately. `low` = batch OK |
| `ttl` | ❌ | Time-to-live in seconds. After expiry, discard without processing |
| `idempotencyKey` | ❌ | For dedup. Same key = same logical message (e.g., alert dedup) |
| `payload.subject` | ✅ | One-line summary (for logging, Slack summaries) |
| `payload.body` | ✅ | The actual content |
| `payload.attachments` | ❌ | Array of `{type, url, name}` for images, files |
| `payload.metadata` | ❌ | Free-form object for routing hints, context |

### Message Types

| Type | Purpose | `replyTo` | `correlationId` |
|------|---------|-----------|------------------|
| `request` | Ask agent to do something and respond | Required | - |
| `response` | Reply to a request | - | Required (original msg ID) |
| `notification` | Informational, no reply expected | - | - |
| `alert` | Urgent notification, may need acknowledgment | Optional | - |
| `ack` | Acknowledgment of receipt/processing | - | Required |

### 5.1 replyContext - Session Routing

The `replyContext` field carries opaque routing metadata from sender to receiver and back. It enables **automatic response routing** to the originating conversation (e.g., a specific Slack thread or chat session).

**Rules:**
- Sender MAY include `replyContext` in a `request`
- Receiver MUST echo `replyContext` back untouched in the `response` - do NOT read, modify, or interpret it
- If `replyContext` contains a `sessionKey` field, MESH scripts automatically:
  1. Set `replyTo.url` to `/hooks/agent` (instead of `/hooks/<agent_name>`) for direct session routing
  2. Include `sessionKey` as a top-level field in the hook POST body
  3. OpenClaw's `/hooks/agent` endpoint reads `sessionKey` and routes to that session

**Why `/hooks/agent`?** OpenClaw's mapped hooks (`/hooks/<name>`) always use the mapping's static `sessionKey`, ignoring any `sessionKey` in the POST body. Only `/hooks/agent` reads `sessionKey` from the body when `allowRequestSessionKey: true`.

**Example flow:**
```
1. Human asks Agent A in Slack thread #123
2. Agent A sends MESH request to Agent B with:
   replyContext: {sessionKey: "agent:main:slack:...:thread:123", ...}
   replyTo: {url: "http://agentA/hooks/agent", token: "..."}
3. Agent B processes, responds with replyContext echoed back
4. mesh-send.sh includes sessionKey in POST body to /hooks/agent
5. OpenClaw routes response to thread #123's session
6. Agent A sees the response in context, presents to human
```

**OpenClaw config required on the receiving side:**
```json
{
  "hooks": {
    "allowRequestSessionKey": true,
    "allowedSessionKeyPrefixes": ["hook:", "agent:main:"]
  }
}
```

### OpenClaw Hook Integration

The envelope is sent as the `message` field in the hook payload:

```json
{
  "message": "<JSON-stringified envelope>"
}
```

The receiving agent's hook session parses the envelope and acts on it. The `message` field is what OpenClaw injects into the agent session.

### Example: Hub → Worker-A Request

```bash
curl -s -X POST http://192.168.1.11:18789/hooks/hub \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer worker1-hook-token" \
  -d '{
    "message": "{\"protocol\":\"mesh/1.0\",\"id\":\"msg_a1b2c3d4\",\"timestamp\":\"2026-02-21T20:45:00Z\",\"from\":\"hub\",\"to\":\"worker-a\",\"type\":\"request\",\"replyTo\":{\"url\":\"http://192.168.1.10:18789/hooks/worker-a\",\"token\":\"hub-hook-token\"},\"priority\":\"normal\",\"ttl\":300,\"payload\":{\"subject\":\"Tank count query\",\"body\":\"How many active tanks are in Zone 5?\"}}"
  }'
```

---

## 6. Layer 3: Conversation Patterns

### Pattern 1: Fire-and-Forget (Notification)

```
Hub ──notification──► Worker-A
       (no reply expected)
```

**Use for:** Status updates, schema pushes, FYI messages.

### Pattern 2: Request-Reply

```
Hub ──request──► Worker-A
       (includes replyTo)
Hub ◄──response── Worker-A
       (correlationId = original id)
```

**Use for:** DB queries, analysis requests, any task that needs a result.

**Contract:**
- Sender includes `replyTo` with URL + token
- Receiver MUST respond within `ttl` seconds (default 300)
- Receiver sends `type: "response"` with `correlationId` set to original `id`
- If receiver can't complete in time, send `type: "ack"` with estimated completion time

### Pattern 3: Request-Reply with ACK

```
Hub ──request──► Worker-A
Hub ◄────ack──── Worker-A (immediate: "received, working on it")
Hub ◄──response── Worker-A (later: actual result)
```

**Use for:** Long-running tasks (DB queries >30s, analysis).

### Pattern 4: Pub-Sub (via Orchestrator)

```
Hub ──notification──► Worker-A
Hub ──notification──► Worker-B
Hub ──notification──► Worker-C
       (same content, different recipients)
```

**Use for:** Schema updates, fleet-wide announcements, broadcast alerts.

### Pattern 5: Rally (Multi-Agent Request-Reply)

```
Hub ──request──► Worker-A
Hub ──request──► Worker-B
Hub ──request──► Worker-E
       (same question, each has replyTo)
Hub ◄──response── Worker-A
Hub ◄──response── Worker-E
Hub ◄──response── Worker-B
       (collect, correlate, synthesize)
```

**Use for:** Cross-agent analysis, consensus queries, multi-perspective reviews.

### Pattern 6: Relay Chain

```
Hub ──request──► Worker-C ──request──► Worker-A
Hub ◄──response── Worker-C ◄──response── Worker-A
```

**Use for:** When Agent A needs Agent C but can't reach it directly, or when intermediate processing is needed.

---

## 7. Layer 4: Orchestration

### Hub as Hub

Hub remains the orchestration hub. All multi-agent workflows route through Hub unless agents have established direct peer links (Tier 1).

### Workflow Definition

For complex multi-step workflows, define them as scripts:

```bash
#!/bin/bash
# workflow: weekly-schema-refresh.sh

# Step 1: Trigger Worker-A to diff schema
RESULT=$(~/mesh/bin/mesh-send.sh worker-a request \
  "Run schema diff against live DB" \
  --wait 480)

# Step 2: If changes found, push to Worker-B
if echo "$RESULT" | jq -e '.payload.metadata.changesFound' > /dev/null; then
  ~/mesh/bin/mesh-send.sh worker-b notification \
    "Schema update from Worker-A: $(echo $RESULT | jq -r '.payload.body')"
fi

# Step 3: Report to Slack
echo "Schema refresh complete" # Hub posts to #alerts
```

### Agent Registration

Each agent's identity is codified in a registry file:

```json
{
  "agents": {
    "hub":    { "ip": "192.168.1.10", "port": 18789, "token": "hub-hook-token",       "role": "hub" },
    "worker-1":    { "ip": "192.168.1.11", "port": 18789, "token": "worker1-hook-token",     "role": "worker" },
    "worker-2":   { "ip": "192.168.1.12", "port": 18789, "token": "worker2-hook-token",    "role": "worker" },
    "worker-3": { "ip": "192.168.1.13", "port": 18789, "token": "worker3-hook-token",  "role": "worker" },
    "worker-4": { "ip": "192.168.1.14", "port": 18789, "token": "worker4-hook-token",  "role": "worker" },
    "worker-5":    { "ip": "192.168.1.15", "port": 18789, "token": "worker5-hook-token",     "role": "worker" },
    "worker-6":  { "ip": "192.168.1.16", "port": 18789, "token": "worker6-hook-token",   "role": "worker" }
  }
}
```

---

## 8. Resilience & Failure Handling

### Retry Strategy

```
Attempt 1: immediate
Attempt 2: wait 5s
Attempt 3: wait 15s
Attempt 4: wait 60s
(give up after 4 attempts)
```

**Only retry on transport failures** (connection refused, timeout, 5xx). Never retry on 4xx (bad request, auth failure).

### Circuit Breaker

Track failures per destination agent:

```
State: CLOSED → OPEN (after 3 consecutive failures)
OPEN: reject all sends for 60s
OPEN → HALF-OPEN: try one message
HALF-OPEN → CLOSED (on success) or OPEN (on failure)
```

Implementation: simple JSON state file at `~/clawd/state/circuit-breakers.json`:

```json
{
  "worker-1": { "state": "closed", "failures": 0, "lastFailure": null, "openUntil": null },
  "worker-2": { "state": "open", "failures": 3, "lastFailure": "2026-02-21T20:00:00Z", "openUntil": "2026-02-21T20:01:00Z" }
}
```

### Timeout Handling

| Scenario | Action |
|----------|--------|
| Transport timeout (10s) | Retry per strategy |
| No ACK within 30s | Log warning, continue waiting |
| No response within TTL | Mark as failed, notify sender |
| Agent health check fails | Circuit breaker opens |

### Dead Letter Queue

Messages that fail all retries get written to `~/clawd/state/dead-letters.json`:

```json
{
  "id": "msg_a1b2c3d4",
  "timestamp": "2026-02-21T20:45:00Z",
  "to": "worker-1",
  "failReason": "circuit_open",
  "attempts": 4,
  "envelope": { ... }
}
```

Hub reviews dead letters during heartbeats and retries or escalates.

---

## 9. Alert Deduplication

### The Problem

Feb 21: Worker-D fired 40+ alerts for the same network outage over 6 hours. Each was processed as a new event, generating duplicate Slack posts and burning tokens.

### Solution: Incident Tracking

Maintain an incident state file at `~/clawd/state/active-incidents.json`:

```json
{
  "incidents": [
    {
      "id": "inc_20260221_lan_outage",
      "type": "network_outage",
      "scope": "lan_segment_all",
      "firstSeen": "2026-02-21T17:30:00Z",
      "lastSeen": "2026-02-21T23:41:00Z",
      "alertCount": 42,
      "affectedHosts": ["worker-1", "worker-2", "worker-3", "worker-4", "worker-5", "worker-6", "gpu-server", "mac-server"],
      "status": "active",
      "escalated": true,
      "lastNotifiedOperator": "2026-02-21T17:57:00Z"
    }
  ]
}
```

### Dedup Rules

1. **Same host + same check + within 30 min of last alert** → suppress, increment counter
2. **New host affected by same root cause** → add to incident, DON'T re-alert
3. **Status change** (partial recovery, full recovery) → always notify
4. **First alert of new incident** → always notify
5. **Hourly summary** during long outages → one consolidated update, not per-alert

### Alert Escalation Policy

```
0-5 min:   Alert the operator (Signal + Slack)
5-60 min:  Hourly summary to Slack only (no Signal unless status change)
60+ min:   Every 2 hours to Slack only
Recovery:  Alert the operator immediately (Signal + Slack)
```

### Implementation

The dedup logic lives in a bash/Python script that runs BEFORE the agent processes an alert:

```bash
# ~/mesh/bin/alert-dedup.sh
# Returns: "new" | "suppressed" | "escalate" | "recovery"
# Used by Worker-D relay cron and all alert-processing hooks
```

---

## 10. Security Model

### Current State

- All inter-agent hooks use `allowUnsafeExternalContent: true`
- This bypasses the `<<<EXTERNAL_UNTRUSTED_CONTENT>>>` safety wrapper
- Justified because: LAN-only, all agents are trusted, all tokens are known

### Improvements

1. **Token rotation schedule:** Rotate all hook tokens quarterly. Document in `HOOK-REGISTRY.md`.
2. **Message signing (future):** HMAC-SHA256 on envelope body with shared secret per agent pair.
3. **Rate limiting:** Each agent should rate-limit inbound hooks (e.g., max 10/min per sender).
4. **Payload size limit:** 64KB per message. Larger payloads → use file reference + HTTP serve.
5. **Audit log:** Every inter-agent message logged to `~/clawd/logs/mesh-audit.jsonl`:

```jsonl
{"ts":"2026-02-21T20:45:00Z","from":"hub","to":"worker-1","type":"request","id":"msg_a1b2c3d4","subject":"Tank count query","status":"sent"}
{"ts":"2026-02-21T20:45:03Z","from":"worker-1","to":"hub","type":"response","id":"msg_e5f6g7h8","correlationId":"msg_a1b2c3d4","status":"received"}
```

---

## 11. Migration Plan

### Phase 1: Foundation (Week 1)

1. **Create `mesh-send.sh`** - CLI tool that wraps envelope creation + HTTP POST + retry + circuit breaker
2. **Create `mesh-receive.sh`** - Parser that hook sessions source to extract envelope fields
3. **Create agent registry** at `~/clawd/config/agent-registry.json`
4. **Create state directory** at `~/clawd/state/` with circuit breakers + dead letters + incidents
5. **Deploy to Hub only** - test with one agent pair (Hub ↔ Worker-A)

### Phase 2: Core Agents (Week 2)

1. **Update Worker-A's AGENTS.md** to recognize MESH envelopes and respond in kind
2. **Update Worker-B's AGENTS.md** similarly
3. **Update Worker-C's AGENTS.md** for structured alert forwarding
4. **Test request-reply pattern** with all three DB/monitoring agents
5. **Implement alert dedup** for Worker-D relay processing

### Phase 3: Full Fleet (Week 3)

1. **Roll out to Worker-E, Worker-D, Worker-F**
2. **Implement rally v3** using MESH envelopes (structured responses, correlation IDs)
3. **Add audit logging**
4. **Document all patterns with examples**

### Phase 4: Hardening (Week 4)

1. **Circuit breaker tuning** based on real failure patterns
2. **Dead letter monitoring** during heartbeats
3. **Performance baseline** - measure latency per agent pair
4. **Token rotation** - first quarterly rotation

### Backward Compatibility

During migration, agents accept BOTH:
- Old format: plain text in `message` field
- New format: JSON envelope in `message` field (detected by `"protocol": "mesh/1.0"`)

This means we can roll out agent-by-agent without breaking existing communication.

---

## 12. Future: Message Bus Option

### When to Consider

If any of these become true:
- More than 10 agents
- Cross-network agents (not just LAN)
- Need for message persistence/replay
- Need for topic-based routing
- Need for guaranteed delivery

### Candidates

| Option | Pros | Cons |
|--------|------|------|
| **NATS** | Lightweight, fast, built-in request-reply, JetStream for persistence | Another service to run |
| **Redis Streams** | Already familiar, can double as cache | Not purpose-built for messaging |
| **MQTT** | IoT-proven, tiny footprint, runs on Pi | No built-in request-reply |
| **ZeroMQ** | No broker needed, peer-to-peer | More complex topology management |
| **Custom HTTP relay** | No new deps, fits OpenClaw model | Reinventing the wheel |

### Recommendation for Future

**NATS** is the best fit if we outgrow HTTP hooks:
- Runs as a single binary (trivial to deploy)
- Built-in request-reply (`nats request/reply`)
- JetStream adds persistence, replay, exactly-once delivery
- 10MB binary, runs happily on a Pi
- Subject-based routing (`fleet.worker-a.db.query`, `fleet.alerts.network`)

But **we don't need this yet.** The MESH protocol over HTTP hooks handles our 7-agent fleet perfectly. The migration to a bus would be straightforward because the envelope format is transport-agnostic.

---

## Rich Media & File Transfer

### The Problem

Agents need to share more than text: database query results (CSV/Excel), generated reports (PDF/DOCX), images (charts, screenshots, floor plans), audio (TTS output, voice notes), and structured data.

### Attachment Types

The `payload.attachments` array supports these types:

```json
{
  "payload": {
    "attachments": [
      {
        "type": "url",
        "url": "http://192.168.1.10:8890/report.xlsx",
        "filename": "zone5-report.xlsx",
        "mimeType": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "size": 245760,
        "description": "Zone 5 tank analysis - Q1 2026"
      },
      {
        "type": "inline",
        "encoding": "base64",
        "data": "UEsDBBQAAAA...",
        "filename": "summary.csv",
        "mimeType": "text/csv",
        "description": "Quick summary table"
      },
      {
        "type": "path",
        "path": "/tmp/shared/chart.png",
        "filename": "production-chart.png",
        "mimeType": "image/png",
        "description": "Production trend chart"
      }
    ]
  }
}
```

### Attachment Type Reference

| Type | When to Use | Size Limit | Notes |
|------|-------------|------------|-------|
| `url` | Large files, images, any binary >64KB | None (HTTP) | Sender serves file via temp HTTP server or permanent path. Receiver must fetch before TTL expires. |
| `inline` | Small files <64KB (CSV summaries, short JSON) | 64KB base64 | Embedded in envelope - no extra HTTP needed. Adds to payload size. |
| `path` | Files on shared filesystem | None | Only works if agents share a mount (e.g., SSHFS, NFS). Path must be accessible to receiver. |

### File Serving Pattern

For `url` type attachments, the sender spins up a temporary HTTP server:

```bash
# Serve a file for 5 minutes on port 8890
cd /tmp && python3 -m http.server 8890 &
SERVER_PID=$!
sleep 300 && kill $SERVER_PID &

# Include in MESH envelope
mesh-send.sh worker-a request "Analyze this report" \
  --attachment "http://192.168.1.10:8890/report.xlsx|application/vnd.openxmlformats-officedocument.spreadsheetml.sheet|Zone 5 report"
```

### Supported MIME Types

| Category | MIME Types | Common Extensions |
|----------|-----------|-------------------|
| **Documents** | `application/pdf`, `application/vnd.openxmlformats-officedocument.wordprocessingml.document`, `text/plain`, `text/markdown` | .pdf, .docx, .txt, .md |
| **Spreadsheets** | `application/vnd.openxmlformats-officedocument.spreadsheetml.sheet`, `text/csv`, `application/json` | .xlsx, .csv, .json |
| **Images** | `image/png`, `image/jpeg`, `image/webp`, `image/gif` | .png, .jpg, .webp, .gif |
| **Audio** | `audio/wav`, `audio/mpeg`, `audio/ogg` | .wav, .mp3, .ogg |
| **Archives** | `application/zip`, `application/gzip` | .zip, .gz |

### Receiver Behavior

When an agent receives an MESH message with attachments:

1. **`url` type:** Fetch the file via HTTP GET before processing. If the URL is unreachable (sender's temp server expired), log and note the failure in the response.
2. **`inline` type:** Base64-decode the `data` field. Write to a temp file if needed for processing.
3. **`path` type:** Check if the path exists and is readable. If not, request the file via URL or flag the error.

### Multi-File Example

Sending a database report with chart and raw data:

```bash
mesh-send.sh worker-a request "Generate Q1 production summary for Zone 5" \
  --attachment "http://192.168.1.10:8890/wells.csv|text/csv|Well list CSV" \
  --attachment "http://192.168.1.10:8890/chart.png|image/png|Production trend chart"
```

---

## Appendix A: Helper Script API

### `mesh-send.sh`

```bash
# Fire-and-forget notification
~/mesh/bin/mesh-send.sh <agent> notification "<message>"

# Request with response wait
~/mesh/bin/mesh-send.sh <agent> request "<message>" --wait <seconds>

# Alert with dedup
~/mesh/bin/mesh-send.sh <agent> alert "<message>" --idempotency-key "<key>"

# Broadcast to all agents
~/mesh/bin/mesh-send.sh all notification "<message>"

# Options:
#   --wait <seconds>     Wait for response (request type only)
#   --priority <level>   high|normal|low
#   --ttl <seconds>      Time-to-live (default 300)
#   --idempotency-key    For dedup
#   --attachment <url>   Attach file/image
#   --metadata <json>    Additional metadata
```

### `mesh-receive.sh` (sourced by hook sessions)

```bash
# In agent's AGENTS.md or hook handler:
# Parse incoming MESH envelope

# Check if message is MESH format
if echo "$MESSAGE" | jq -e '.protocol == "mesh/1.0"' > /dev/null 2>&1; then
  MSG_ID=$(echo "$MESSAGE" | jq -r '.id')
  MSG_TYPE=$(echo "$MESSAGE" | jq -r '.type')
  MSG_FROM=$(echo "$MESSAGE" | jq -r '.from')
  MSG_BODY=$(echo "$MESSAGE" | jq -r '.payload.body')
  REPLY_URL=$(echo "$MESSAGE" | jq -r '.replyTo.url // empty')
  REPLY_TOKEN=$(echo "$MESSAGE" | jq -r '.replyTo.token // empty')
  CORRELATION_ID=$(echo "$MESSAGE" | jq -r '.correlationId // empty')
fi
```

---

## Appendix B: Message Flow Diagrams

### Successful Request-Reply

```
Time
  │
  │  Hub                          Worker-A
  │    │                              │
  │    │──POST /hooks/hub──────────►│
  │    │  {type:"request",            │
  │    │   replyTo:{hub:hooks/worker-a}│
  │    │   body:"Count tanks zone 5"} │
  │    │                              │
  │    │           HTTP 202           │
  │    │◄─────────────────────────────│
  │    │                              │
  │    │                        [processes query]
  │    │                              │
  │    │◄──POST /hooks/worker-a──────────│
  │    │  {type:"response",           │
  │    │   correlationId:orig.id,     │
  │    │   body:"47 active tanks"}    │
  │    │                              │
  │    │           HTTP 202           │
  │    │──────────────────────────────►│
  ▼
```

### Failed Request with Retry

```
Time
  │
  │  Hub                          Worker-A (down)
  │    │                              │
  │    │──POST──────────────────────► ✗ (connection refused)
  │    │  [wait 5s]                   │
  │    │──POST──────────────────────► ✗ (connection refused)
  │    │  [wait 15s]                  │
  │    │──POST──────────────────────► ✗ (connection refused)
  │    │  [wait 60s]                  │
  │    │──POST──────────────────────► ✗ (connection refused)
  │    │                              │
  │    │  [circuit breaker OPENS]     │
  │    │  [write to dead-letter queue]│
  │    │  [log failure]               │
  ▼
```

---

## Appendix C: Comparison with Current System

| Aspect | Current | MESH Protocol |
|--------|---------|----------------|
| Message format | Free text in `message` field | Structured JSON envelope |
| Response routing | Embedded curl commands in natural language | `replyTo` field with URL + token |
| Delivery confirmation | None (HTTP 202 only) | ACK messages + correlation IDs |
| Retry | None | 4-attempt exponential backoff |
| Dedup | None | `idempotencyKey` field |
| Alert suppression | None (40+ dupes per incident) | Incident tracking + dedup rules |
| Circuit breaking | None | Per-agent state tracking |
| Dead letters | None (lost forever) | Persisted + reviewed on heartbeat |
| Audit trail | None | JSONL audit log |
| Security | Shared tokens, no rotation | Same tokens + rotation schedule |
| Backward compat | N/A | Detects old vs new format |

---

*"The difference between a protocol and a hack is documentation."*
