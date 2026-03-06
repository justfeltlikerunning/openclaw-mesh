# MESH Dashboard Panel

Optional dashboard widget for monitoring MESH protocol traffic.

## Files

- `mesh-api.py` - Python module with `collect_mesh_data()` function for your dashboard backend
- `mesh-panel.html` - Standalone HTML/JS panel widget (copy into your dashboard)

## Integration

### Backend (Python)

Add to your dashboard's HTTP server:

```python
from mesh_api import collect_mesh_data

# In your request handler:
elif path == "/api/mesh":
    data = collect_mesh_data()
    self.send_json(data)
```

### Frontend (HTML)

Copy the contents of `mesh-panel.html` into your dashboard HTML. The panel:
- Auto-fetches `/api/mesh` every 30 seconds
- Shows stats: total sent, last 24h, failed, dead letters, incidents
- Clickable agent filter chips
- Expandable message detail on row click
- Circuit breaker status per agent
- Active incident display

### Environment

Set `MESH_HOME` so the API module can find your MESH installation:

```bash
export MESH_HOME="/path/to/.mesh"
```
