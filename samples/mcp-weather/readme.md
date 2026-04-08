# MCP Weather Server

A minimal MCP (Model Context Protocol) server that exposes a single `get_weather` tool. Returns random weather data for any location.

## What is MCP?

MCP is an open protocol that lets AI applications (like Claude) connect to external tools and data sources. An MCP server exposes **tools** that AI clients can discover and call. This sample uses Streamable HTTP transport so it can run as a Kubernetes service.

Key concepts:
- **Tool** — a function the AI can call (like a REST endpoint, but for AI agents)
- **Streamable HTTP transport** — HTTP-based transport where the server exposes a single `/mcp` endpoint that accepts both GET and POST
- **MCP Inspector** — a browser-based tool for testing MCP servers interactively

## Service Details

| Property | Value |
|----------|-------|
| Port | 8000 |
| Transport | Streamable HTTP |
| MCP Endpoint | `http://mcp-weather.apim.svc:8000/mcp` |
| Tools | `get_weather(location: str)` |

## Run Locally

No Docker or Kubernetes needed — just Python 3.10+.

```bash
# Install Python 3.12 if you don't have it (macOS ships with 3.9)
brew install python@3.12

cd samples/mcp-weather/src
python3.12 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python main.py
```

The server starts on `http://localhost:8000` with the MCP endpoint at `http://localhost:8000/mcp`.

### Test with MCP Inspector (local)

```bash
npx @modelcontextprotocol/inspector
```

In the Inspector UI, set transport to **Streamable HTTP**, enter `http://localhost:8000/mcp`, and click **Connect**. Go to the **Tools** tab, select `get_weather`, enter `{"location": "Colombo"}`, and call it.

### Connect from Claude Desktop (local)

Add this to your Claude Desktop config (`~/Library/Application Support/Claude/claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "weather": {
      "command": "python",
      "args": ["/full/path/to/samples/mcp-weather/src/main.py"]
    }
  }
}
```

> **Note:** Claude Desktop launches MCP servers as subprocesses using stdio. The `mcp` SDK's `FastMCP.run()` auto-detects the transport — when launched by Claude Desktop it uses stdio, when run directly it uses Streamable HTTP.

---

## Deploy (Kubernetes)

```bash
./samples/mcp-weather/deploy-multi-dc.sh
```

Verify:
```bash
# DC1
kubectl config use-context aks-apim-eus1
kubectl get pods -n apim -l app.kubernetes.io/name=mcp-weather

# DC2
kubectl config use-context aks-apim-wus2
kubectl get pods -n apim -l app.kubernetes.io/name=mcp-weather
```

## Register in WSO2 APIM

1. Open Publisher: `https://cp.eus1.apim.example.com/publisher`
2. Click **Create MCP Server** > **MCP Server URL**
3. Enter: `http://mcp-weather.apim.svc:8000` (no `/mcp` suffix — APIM appends it)
4. APIM will discover the `get_weather` tool automatically
5. Deploy and Publish

## Test with MCP Inspector (through APIM Gateway)

1. Launch the Inspector with TLS verification disabled (self-signed cert):
   ```bash
   NODE_TLS_REJECT_UNAUTHORIZED=0 npx @modelcontextprotocol/inspector
   ```

2. In the Inspector UI:
   - Set transport to **Streamable HTTP**
   - Enter URL: `https://gw.eus1.apim.example.com/wathermcp/1/mcp`
   - Click **Connect**
   - Go to the **Tools** tab — you should see `get_weather`
   - Call it with `{"location": "New York"}` — you'll get random weather data

> **Note:** `NODE_TLS_REJECT_UNAUTHORIZED=0` is needed because the gateway uses a self-signed certificate.

## Test with MCP Inspector (direct, via port-forward)

1. Port-forward the service:
   ```bash
   kubectl -n apim port-forward svc/mcp-weather-mcp-weather 8000:8000
   ```

2. Launch the MCP Inspector:
   ```bash
   npx @modelcontextprotocol/inspector
   ```

3. In the Inspector UI:
   - Set transport to **Streamable HTTP**
   - Enter URL: `http://localhost:8000/mcp`
   - Click **Connect**

## Teardown

```bash
./samples/mcp-weather/undeploy-multi-dc.sh
```
