# Building the Webhook Orders Image

The webhook-orders image must be built for multiple platforms since development happens on Mac (ARM64) but AKS nodes run AMD64.

## Prerequisites

- Docker Desktop with buildx enabled (included by default in Docker Desktop 4.x+)
- Logged in to Docker Hub: `docker login`

## Build and Push (Multi-Platform)

From the repo root:

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t isurugunarathne/webhook-orders:latest \
  --push \
  ./samples/webhook-orders/src/
```

> **Note:** `--push` is required because multi-platform manifests can't be stored in the local Docker daemon.

### Verify the manifest

```bash
docker manifest inspect isurugunarathne/webhook-orders:latest
```

Should show entries for both `amd64` and `arm64` architectures.

## Redeploy on AKS

If pods are already running, delete them to trigger a re-pull:

```bash
kubectl delete pod -l app.kubernetes.io/name=webhook-orders -n apim
```

## Local Build (single platform, for dev only)

```bash
cd samples/webhook-orders/src
docker build -t isurugunarathne/webhook-orders:latest .
```

## Local Test

```bash
docker run -p 8000:8000 isurugunarathne/webhook-orders:latest
curl -X POST http://localhost:8000/trigger    # generates event (no hub configured)
curl http://localhost:8000/deliveries         # list received callbacks
```
