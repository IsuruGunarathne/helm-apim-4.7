# WSO2 APIM 4.7.0 Distributed Docker Images

Build and push Docker images for WSO2 API Manager distributed components (Control Plane, Gateway, Traffic Manager).

## Prerequisites

- Java 21 (Eclipse Temurin)
- Maven 3.9+
- Docker Desktop / Rancher Desktop with buildx
- Docker Hub account with access to `isurugunarathne/wso2apim`

## Build from Source

### 1. Maven Build

```bash
cd ../product-apim
mvn clean install -DskipTests
```

This produces ZIP distributions in each component's `modules/distribution/product/target/` directory.

### 2. Build and Push Docker Images

```bash
# Ensure Docker is running and you're logged in
docker login --username isurugunarathne

# Run the build script
./build-and-push.sh
```

This builds all 3 images for `linux/amd64` and pushes them to Docker Hub:

| Component | Image Tag |
|-----------|-----------|
| Control Plane | `isurugunarathne/wso2apim:acp-4.7.0-beta` |
| Gateway | `isurugunarathne/wso2apim:gw-4.7.0-beta` |
| Traffic Manager | `isurugunarathne/wso2apim:tm-4.7.0-beta` |

### 3. Build Individual Images

To build a single component manually:

```bash
# Copy the ZIP into this directory first
cp ../product-apim/api-control-plane/modules/distribution/product/target/wso2am-acp-4.7.0-SNAPSHOT.zip .

docker buildx build \
  --no-cache \
  --platform linux/amd64 \
  --build-arg WSO2_SERVER_NAME=wso2am-acp \
  --build-arg WSO2_SERVER_VERSION=4.7.0-SNAPSHOT \
  --build-arg ZIP_FILE=wso2am-acp-4.7.0-SNAPSHOT.zip \
  --build-arg STARTUP_SCRIPT=api-cp.sh \
  -t isurugunarathne/wso2apim:acp-4.7.0-beta \
  --push .
```

**Startup scripts per component:**
- Control Plane: `api-cp.sh`
- Gateway: `gateway.sh`
- Traffic Manager: `traffic-manager.sh`

## Pulling from a Private Registry

If `isurugunarathne/wso2apim` is a private Docker Hub repository, Kubernetes needs credentials to pull images. Use an `imagePullSecret` attached to a service account.

### 1. Create the namespace

```bash
kubectl create namespace apim
```

### 2. Create a Docker Hub access token

Go to https://hub.docker.com/settings/security and create an access token.

### 3. Create the Kubernetes secret

```bash
kubectl create secret docker-registry regcred \
  --docker-server=docker.io \
  --docker-username=isurugunarathne \
  --docker-password=<your-dockerhub-access-token> \
  -n apim
```

### 4. Patch the service account

All deployments (local and Azure) use the `default` service account unless `azure.serviceAccountName` is explicitly set in the Helm values:

```bash
kubectl patch serviceaccount default -n apim \
  -p '{"imagePullSecrets": [{"name": "regcred"}]}'
```

### 5. Verify

```bash
kubectl get serviceaccount default -n apim -o yaml
```

You should see:

```yaml
imagePullSecrets:
- name: regcred
```

All pods in the `apim` namespace will now automatically use these credentials to pull images.

> **Note:** If the repository is public, no `imagePullSecret` is needed.

## Cross-Platform Build Notes

- On Apple Silicon Macs, `docker buildx` uses QEMU emulation to build `linux/amd64` images. Expect ~10-20 minutes per image.
- The `--push` flag pushes directly from the buildx builder to Docker Hub without loading into the local daemon (required for foreign-architecture images).
- The `--no-cache` flag ensures a clean build every time.
