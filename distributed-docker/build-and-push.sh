#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"
PRODUCT_APIM="${PROJECT_ROOT}/product-apim"
REPO="isurugunarathne/wso2apim"

cd "${SCRIPT_DIR}"

# --- Maven Build ---
echo "=== Building from source (mvn clean install -DskipTests) ==="
echo "=== This builds: api-control-plane, gateway, traffic-manager, all-in-one-apim ==="
cd "${PRODUCT_APIM}"
mvn clean install -DskipTests -pl api-control-plane,gateway,traffic-manager -am
cd "${SCRIPT_DIR}"

echo ""
echo "=== Copying ZIP artifacts from Maven build output ==="
cp "${PRODUCT_APIM}/api-control-plane/modules/distribution/product/target/wso2am-acp-4.7.0-SNAPSHOT.zip" .
cp "${PRODUCT_APIM}/gateway/modules/distribution/product/target/wso2am-universal-gw-4.7.0-SNAPSHOT.zip" .
cp "${PRODUCT_APIM}/traffic-manager/modules/distribution/product/target/wso2am-tm-4.7.0-SNAPSHOT.zip" .

echo "=== Setting up buildx builder ==="
docker buildx create --name wso2builder --use 2>/dev/null || docker buildx use wso2builder
docker buildx inspect --bootstrap

echo ""
echo "=== Building and pushing Control Plane ==="
docker buildx build \
  --no-cache \
  --platform linux/amd64 \
  --build-arg WSO2_SERVER_NAME=wso2am-acp \
  --build-arg WSO2_SERVER_VERSION=4.7.0-SNAPSHOT \
  --build-arg ZIP_FILE=wso2am-acp-4.7.0-SNAPSHOT.zip \
  --build-arg STARTUP_SCRIPT=api-cp.sh \
  -t "${REPO}:acp-4.7.0-beta" \
  --push \
  .

echo ""
echo "=== Building and pushing Gateway ==="
docker buildx build \
  --no-cache \
  --platform linux/amd64 \
  --build-arg WSO2_SERVER_NAME=wso2am-universal-gw \
  --build-arg WSO2_SERVER_VERSION=4.7.0-SNAPSHOT \
  --build-arg ZIP_FILE=wso2am-universal-gw-4.7.0-SNAPSHOT.zip \
  --build-arg STARTUP_SCRIPT=gateway.sh \
  -t "${REPO}:gw-4.7.0-beta" \
  --push \
  .

echo ""
echo "=== Building and pushing Traffic Manager ==="
docker buildx build \
  --no-cache \
  --platform linux/amd64 \
  --build-arg WSO2_SERVER_NAME=wso2am-tm \
  --build-arg WSO2_SERVER_VERSION=4.7.0-SNAPSHOT \
  --build-arg ZIP_FILE=wso2am-tm-4.7.0-SNAPSHOT.zip \
  --build-arg STARTUP_SCRIPT=traffic-manager.sh \
  -t "${REPO}:tm-4.7.0-beta" \
  --push \
  .

# Cleanup ZIPs from build context
rm -f wso2am-acp-4.7.0-SNAPSHOT.zip wso2am-universal-gw-4.7.0-SNAPSHOT.zip wso2am-tm-4.7.0-SNAPSHOT.zip

echo ""
echo "=== All images pushed successfully ==="
echo "Verify with:"
echo "  docker buildx imagetools inspect ${REPO}:acp-4.7.0-beta"
echo "  docker buildx imagetools inspect ${REPO}:gw-4.7.0-beta"
echo "  docker buildx imagetools inspect ${REPO}:tm-4.7.0-beta"
