# MESH Receivers

MESH works with any framework that can receive HTTP POST requests. These examples show how to integrate with non-OpenClaw systems.

## Generic Receiver (any framework)

A standalone Python HTTP server that receives MESH messages. No dependencies beyond Python 3.

```bash
# Start receiver
MESH_AGENT=myagent python3 generic-receiver.py --port 8900

# With a handler script (processes messages automatically)
MESH_HANDLER=./handler-example.sh MESH_AGENT=myagent python3 generic-receiver.py
```

**Two modes:**

1. **Inbox mode** (default) - Messages queue in memory. Your framework polls `GET /inbox` to retrieve them.
2. **Handler mode** - Set `MESH_HANDLER` to a script/binary. Each message is piped to stdin; response JSON goes to stdout.

**Endpoints:**
| Endpoint | Method | Description |
|----------|--------|-------------|
| `/hooks/*` | POST | Receive MESH messages (any path works) |
| `/inbox` | GET | Retrieve queued messages |
| `/health` | GET | Health check |

## Integration Examples

### CrewAI
```python
# In your CrewAI agent, poll the inbox:
import requests
messages = requests.get("http://localhost:8900/inbox").json()["messages"]
for msg in messages:
    task = msg["payload"]["body"]
    # Feed to CrewAI agent...
```

### AutoGen
```python
# AutoGen agent polling MESH inbox
import requests, json
inbox = requests.get("http://localhost:8900/inbox").json()
for envelope in inbox["messages"]:
    # Convert MESH message to AutoGen message format
    content = envelope["payload"]["body"]
    sender = envelope["from"]
    # agent.receive(content, sender)
```

### LangGraph / LangChain
```python
# Use handler mode with a Python script:
# MESH_HANDLER=./langchain-handler.py python3 generic-receiver.py

# langchain-handler.py:
import sys, json
envelope = json.loads(sys.stdin.read())
query = envelope["payload"]["body"]
# result = chain.invoke({"query": query})
# print(json.dumps({"body": str(result)}))
```

### Docker
```dockerfile
FROM python:3.11-slim
COPY generic-receiver.py /app/
ENV MESH_AGENT=myagent
EXPOSE 8900
CMD ["python3", "/app/generic-receiver.py"]
```

## Connecting to OpenClaw Agents

In the MESH registry on your OpenClaw agent, point to the generic receiver:

```json
{
  "agents": {
    "crewai-agent": {
      "ip": "192.168.1.50",
      "port": 8900,
      "token": "your-token",
      "role": "peer",
      "hookPath": "/hooks/myagent"
    }
  }
}
```

Now your OpenClaw agent can send messages to CrewAI:
```bash
mesh-send.sh crewai-agent request "Analyze this dataset"
```

And the CrewAI agent can respond via the generic receiver's reply mechanism.
