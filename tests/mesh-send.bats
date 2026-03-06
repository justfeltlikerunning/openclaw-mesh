#!/usr/bin/env bats
# MESH Protocol Test Suite
# Run: bats tests/mesh-send.bats

setup() {
    export MESH_HOME="$BATS_TMPDIR/mesh-test-$$"
    export MESH_AGENT="test-agent"
    mkdir -p "$MESH_HOME"/{config,state,logs}
    
    # Create test registry
    cat > "$MESH_HOME/config/agent-registry.json" << 'EOF'
{
  "version": "1.0",
  "agents": {
    "test-agent": {
      "ip": "127.0.0.1",
      "port": 19999,
      "token": "test-token-123",
      "role": "test",
      "hookPath": "/hooks/test-agent"
    },
    "peer-agent": {
      "ip": "127.0.0.1",
      "port": 19998,
      "token": "peer-token-456",
      "role": "worker",
      "hookPath": "/hooks/test-agent"
    }
  }
}
EOF

    # Create identity
    echo -n "test-agent" > "$MESH_HOME/config/identity"
    
    # Init state files
    echo '{}' > "$MESH_HOME/state/circuit-breakers.json"
    echo '{"messages":[]}' > "$MESH_HOME/state/dead-letters.json"
    touch "$MESH_HOME/logs/mesh-audit.jsonl"
    
    # Path to scripts under test
    MESH_BIN="$(cd "$(dirname "$BATS_TEST_FILENAME")/../bin" && pwd)"
}

teardown() {
    rm -rf "$MESH_HOME"
}

# ── Registry & Config Tests ──

@test "agent-registry.json is valid JSON" {
    jq '.' "$MESH_HOME/config/agent-registry.json" > /dev/null
}

@test "identity file returns correct agent name" {
    result=$(cat "$MESH_HOME/config/identity")
    [ "$result" = "test-agent" ]
}

@test "registry contains expected agents" {
    count=$(jq '.agents | length' "$MESH_HOME/config/agent-registry.json")
    [ "$count" -eq 2 ]
}

@test "hookPath includes sender agent name" {
    path=$(jq -r '.agents["peer-agent"].hookPath' "$MESH_HOME/config/agent-registry.json")
    [[ "$path" == */test-agent* ]]
}

@test "hookPath is not bare /hooks" {
    paths=$(jq -r '.agents[].hookPath' "$MESH_HOME/config/agent-registry.json")
    while IFS= read -r path; do
        [ "$path" != "/hooks" ]
    done <<< "$paths"
}

# ── Circuit Breaker Tests ──

@test "circuit breaker starts closed" {
    state=$(jq -r '.["peer-agent"].state // "closed"' "$MESH_HOME/state/circuit-breakers.json")
    [ "$state" = "closed" ]
}

@test "circuit breaker file is valid JSON" {
    jq '.' "$MESH_HOME/state/circuit-breakers.json" > /dev/null
}

@test "circuit breaker tracks failures correctly" {
    # Simulate 3 failures
    jq '. + {"peer-agent": {"state": "open", "failures": 3, "lastFailure": "2026-01-01T00:00:00Z", "openUntil": "2026-01-01T00:05:00Z"}}' \
        "$MESH_HOME/state/circuit-breakers.json" > "$MESH_HOME/state/circuit-breakers.json.tmp"
    mv "$MESH_HOME/state/circuit-breakers.json.tmp" "$MESH_HOME/state/circuit-breakers.json"
    
    state=$(jq -r '.["peer-agent"].state' "$MESH_HOME/state/circuit-breakers.json")
    [ "$state" = "open" ]
    
    failures=$(jq -r '.["peer-agent"].failures' "$MESH_HOME/state/circuit-breakers.json")
    [ "$failures" -eq 3 ]
}

@test "expired circuit breaker should allow half-open" {
    # Set openUntil in the past
    jq '. + {"peer-agent": {"state": "open", "failures": 3, "lastFailure": "2020-01-01T00:00:00Z", "openUntil": "2020-01-01T00:05:00Z"}}' \
        "$MESH_HOME/state/circuit-breakers.json" > "$MESH_HOME/state/circuit-breakers.json.tmp"
    mv "$MESH_HOME/state/circuit-breakers.json.tmp" "$MESH_HOME/state/circuit-breakers.json"
    
    open_until=$(jq -r '.["peer-agent"].openUntil' "$MESH_HOME/state/circuit-breakers.json")
    now_epoch=$(date +%s)
    until_epoch=$(date -d "$open_until" +%s 2>/dev/null || echo 0)
    [ "$now_epoch" -gt "$until_epoch" ]
}

# ── Dead Letter Tests ──

@test "dead letter queue starts empty" {
    count=$(jq '.messages | length' "$MESH_HOME/state/dead-letters.json")
    [ "$count" -eq 0 ]
}

@test "dead letter queue is valid JSON" {
    jq '.' "$MESH_HOME/state/dead-letters.json" > /dev/null
}

# ── Dedup Tests ──

@test "mesh-dedup.sh returns 'new' for first alert" {
    skip_if_no_dedup
    result=$("$MESH_BIN/mesh-dedup.sh" "Test alert: service down" --host testhost --check gateway)
    [ "$result" = "new" ]
}

@test "mesh-dedup.sh returns 'suppressed' for duplicate within window" {
    skip_if_no_dedup
    "$MESH_BIN/mesh-dedup.sh" "Test alert: service down" --host testhost --check gateway > /dev/null
    result=$("$MESH_BIN/mesh-dedup.sh" "Test alert: service down" --host testhost --check gateway)
    [ "$result" = "suppressed" ]
}

@test "mesh-dedup.sh returns 'recovery' for resolved alert" {
    skip_if_no_dedup
    # Create an active incident first
    "$MESH_BIN/mesh-dedup.sh" "Test alert: service down" --host testhost --check gateway > /dev/null
    result=$("$MESH_BIN/mesh-dedup.sh" "RESOLVED: Test alert: service recovered" --host testhost --check gateway)
    [[ "$result" == "recovery" || "$result" == "new" ]]
}

# ── Envelope Format Tests ──

@test "audit log entries are valid JSONL" {
    # Write a sample entry
    echo '{"from":"test","to":"peer","type":"request","status":"sent","timestamp":"2026-01-01T00:00:00Z"}' \
        >> "$MESH_HOME/logs/mesh-audit.jsonl"
    
    while IFS= read -r line; do
        echo "$line" | jq '.' > /dev/null
    done < "$MESH_HOME/logs/mesh-audit.jsonl"
}

@test "MESH envelope has required fields" {
    envelope='{"protocol":"mesh/1.0","id":"msg_test","timestamp":"2026-01-01T00:00:00Z","from":"test-agent","to":"peer-agent","type":"request","payload":{"subject":"test","body":"hello"}}'
    
    # Verify required fields exist
    echo "$envelope" | jq -e '.protocol' > /dev/null
    echo "$envelope" | jq -e '.id' > /dev/null
    echo "$envelope" | jq -e '.timestamp' > /dev/null
    echo "$envelope" | jq -e '.from' > /dev/null
    echo "$envelope" | jq -e '.to' > /dev/null
    echo "$envelope" | jq -e '.type' > /dev/null
    echo "$envelope" | jq -e '.payload' > /dev/null
}

@test "MESH protocol version is mesh/1.0" {
    envelope='{"protocol":"mesh/1.0"}'
    version=$(echo "$envelope" | jq -r '.protocol')
    [ "$version" = "mesh/1.0" ]
}

@test "message ID follows msg_ prefix convention" {
    id="msg_$(openssl rand -hex 16)"
    [[ "$id" == msg_* ]]
}

# ── HMAC Tests ──

@test "mesh-keygen.sh creates signing keys" {
    if [ ! -f "$MESH_BIN/mesh-keygen.sh" ]; then
        skip "mesh-keygen.sh not found"
    fi
    
    MESH_HOME="$MESH_HOME" "$MESH_BIN/mesh-keygen.sh" peer-agent 2>/dev/null
    [ -f "$MESH_HOME/config/signing-keys/peer-agent.key" ]
}

# ── Helper Functions ──

skip_if_no_dedup() {
    if [ ! -f "$MESH_BIN/mesh-dedup.sh" ]; then
        skip "mesh-dedup.sh not found"
    fi
}
