# Building the GraphQL Books Image

The image must be built for multiple platforms since development happens on Mac (ARM64)
but AKS nodes run AMD64. A single-platform ARM64 image will fail to pull on AKS with
`no match for platform in manifest`.

## Prerequisites

- Docker Desktop with buildx enabled (included by default in Docker Desktop 4.x+)
- Logged in to Docker Hub: `docker login`

## Build and Push (Multi-Platform)

From the repo root:

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t isurugunarathne/graphql-books:latest \
  --push \
  ./samples/graphql-books/src/
```

> **Note:** `--push` is required because multi-platform manifests can't be stored in
> the local Docker daemon — they're pushed directly to the registry.

### Verify the manifest

```bash
docker manifest inspect isurugunarathne/graphql-books:latest
```

Should show entries for both `amd64` and `arm64` architectures.

## Redeploy on AKS

If pods are already running, delete them to trigger a re-pull:

```bash
kubectl delete pod -l app.kubernetes.io/name=graphql-books -n apim
```

## Local Build (single platform, for dev only)

```bash
cd samples/graphql-books/src
docker build -t isurugunarathne/graphql-books:latest .
docker run -p 8000:8000 isurugunarathne/graphql-books:latest
```

This builds for the host platform only. Fine for local testing with `docker run`,
but will not work on AKS if built on an ARM Mac.
