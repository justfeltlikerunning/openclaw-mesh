#!/usr/bin/env bash
# mesh-crypt.sh - Envelope encryption/decryption for MESH messages
#
# Encrypts the payload body using AES-256-CBC with a shared key.
# The envelope metadata (from, to, type, timestamp) stays cleartext
# for routing. Only the payload.body gets encrypted.
#
# Usage:
#   mesh-crypt.sh encrypt <agent> <plaintext>    # Returns encrypted body
#   mesh-crypt.sh decrypt <agent> <ciphertext>   # Returns plaintext
#   mesh-crypt.sh keygen <agent>                 # Generate shared encryption key
#
# Keys stored at: $MESH_HOME/config/encryption-keys/<agent>.key
#
# To enable encryption on send:
#   mesh-send.sh <agent> request "secret message" --encrypt
#
# This is separate from signing (HMAC). Signing proves who sent it.
# Encryption hides what was sent.

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

ENCRYPT_KEYS="$MESH_HOME/config/encryption-keys"
mkdir -p "$ENCRYPT_KEYS"

cmd="${1:-help}"
shift || true

case "$cmd" in
    encrypt)
        AGENT="${1:?Agent name required}"
        PLAINTEXT="${2:-$(cat)}"
        KEY_FILE="$ENCRYPT_KEYS/${AGENT}.key"
        
        if [ ! -f "$KEY_FILE" ]; then
            # Fall back to fleet-wide key
            KEY_FILE="$ENCRYPT_KEYS/fleet.key"
        fi
        
        if [ ! -f "$KEY_FILE" ]; then
            echo "ERROR: No encryption key for '$AGENT' or 'fleet'. Run: mesh-crypt.sh keygen $AGENT" >&2
            exit 1
        fi
        
        KEY=$(cat "$KEY_FILE" | tr -d '[:space:]')
        
        # Generate random IV
        IV=$(openssl rand -hex 16)
        
        # Encrypt with AES-256-CBC
        CIPHERTEXT=$(echo -n "$PLAINTEXT" | openssl enc -aes-256-cbc -base64 -A \
            -K "$(echo -n "$KEY" | xxd -p | tr -d '\n' | head -c 64)" \
            -iv "$IV" 2>/dev/null)
        
        # Output as JSON with IV prefix
        echo "{\"enc\":\"aes-256-cbc\",\"iv\":\"${IV}\",\"data\":\"${CIPHERTEXT}\"}"
        ;;
    
    decrypt)
        AGENT="${1:?Agent name required}"
        CIPHERTEXT="${2:-$(cat)}"
        KEY_FILE="$ENCRYPT_KEYS/${AGENT}.key"
        
        if [ ! -f "$KEY_FILE" ]; then
            KEY_FILE="$ENCRYPT_KEYS/fleet.key"
        fi
        
        if [ ! -f "$KEY_FILE" ]; then
            echo "ERROR: No encryption key for '$AGENT'" >&2
            exit 1
        fi
        
        KEY=$(cat "$KEY_FILE" | tr -d '[:space:]')
        
        # Parse encryption envelope
        IV=$(echo "$CIPHERTEXT" | jq -r '.iv')
        DATA=$(echo "$CIPHERTEXT" | jq -r '.data')
        
        # Decrypt
        echo -n "$DATA" | openssl enc -aes-256-cbc -d -base64 -A \
            -K "$(echo -n "$KEY" | xxd -p | tr -d '\n' | head -c 64)" \
            -iv "$IV" 2>/dev/null
        ;;
    
    keygen)
        AGENT="${1:-fleet}"
        KEY_FILE="$ENCRYPT_KEYS/${AGENT}.key"
        
        if [ -f "$KEY_FILE" ]; then
            echo "Key already exists for '$AGENT' at $KEY_FILE"
            echo "Delete it first if you want to regenerate."
            exit 1
        fi
        
        # Generate 256-bit key
        KEY=$(openssl rand -hex 32)
        echo "$KEY" > "$KEY_FILE"
        chmod 600 "$KEY_FILE"
        
        echo "✓ Generated encryption key for '$AGENT'"
        echo "  Location: $KEY_FILE"
        echo ""
        echo "  Copy to the other node:"
        echo "  scp $KEY_FILE peer:$ENCRYPT_KEYS/${AGENT}.key"
        ;;
    
    help|*)
        echo "mesh-crypt.sh - MESH envelope encryption"
        echo ""
        echo "Usage:"
        echo "  mesh-crypt.sh encrypt <agent> <plaintext>"
        echo "  mesh-crypt.sh decrypt <agent> <ciphertext>"
        echo "  mesh-crypt.sh keygen [agent|fleet]"
        echo ""
        echo "Keys: $ENCRYPT_KEYS/"
        ;;
esac
