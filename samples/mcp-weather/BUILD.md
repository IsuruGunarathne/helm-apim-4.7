# Building the MCP Weather Server Image

The mcp-weather image must be built for multiple platforms since development happens on Mac (ARM64) but AKS nodes run AMD64.

## Prerequisites

- Docker Desktop with buildx enabled (included by default in Docker Desktop 4.x+)
- Logged in to Docker Hub: `docker login`

## Build and Push (Multi-Platform)

From the repo root:

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t isurugunarathne/mcp-weather:latest \
  --push \
  ./samples/mcp-weather/src/
```

> **Note:** `--push` is required because multi-platform manifests can't be stored in the local Docker daemon.

### Verify the manifest

```bash
docker manifest inspect isurugunarathne/mcp-weather:latest
```

Should show entries for both `amd64` and `arm64` architectures.

## Redeploy on AKS

If pods are already running, delete them to trigger a re-pull:

```bash
kubectl delete pod -l app.kubernetes.io/name=mcp-weather -n apim
```

## Local Build (single platform, for dev only)

```bash
cd samples/mcp-weather/src
docker build -t isurugunarathne/mcp-weather:latest .
```

## Local Test

```bash
docker run -p 8000:8000 isurugunarathne/mcp-weather:latest
# MCP SSE endpoint at http://localhost:8000/sse
# Test with: npx @modelcontextprotocol/inspector
```
