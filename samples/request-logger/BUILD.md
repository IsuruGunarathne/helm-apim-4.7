# Building the Request Logger Image

The request-logger image must be built for multiple platforms since development happens on Mac (ARM64) but AKS nodes run AMD64. A single-platform ARM64 image will fail to pull on AKS with `no match for platform in manifest`.

## Prerequisites

- Docker Desktop with buildx enabled (included by default in Docker Desktop 4.x+)
- Logged in to Docker Hub: `docker login`

## Build and Push (Multi-Platform)

From the repo root:

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t isurugunarathne/request-logger:latest \
  --push \
  ./samples/request-logger/src/
```

> **Note:** `--push` is required because multi-platform manifests can't be stored in the local Docker daemon — they're pushed directly to the registry. This uses the default buildx builder — no custom builder setup needed.

### Verify the manifest

```bash
docker manifest inspect isurugunarathne/request-logger:latest
```

Should show entries for both `amd64` and `arm64` architectures.

## Redeploy on AKS

If pods are already running (or stuck in `ErrImagePull`), delete them to trigger a re-pull:

```bash
kubectl delete pod -l app.kubernetes.io/name=request-logger -n apim
```

## Local Build (single platform, for dev only)

```bash
cd samples/request-logger/src
docker build -t isurugunarathne/request-logger:latest .
```

This builds for the host platform only. Fine for local testing with `docker run` or Kind/Minikube, but will not work on AKS if built on an ARM Mac.
