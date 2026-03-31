#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WAR_SOURCE="$SCRIPT_DIR/../product-apim/all-in-one-apim/modules/integration/tests-integration/tests-backend/src/test/resources/artifacts/AM/war"
IMAGE="isurugunarathne/apim-test-backends:latest"

echo "=== Test Backends — Build & Push ==="
echo ""

# -------------------------------------------------------
# Copy WAR files
# -------------------------------------------------------
echo "Copying WAR files..."
cp "$WAR_SOURCE"/*.war "$SCRIPT_DIR/test-backends/war/"
echo "Copied $(ls "$SCRIPT_DIR/test-backends/war/"*.war | wc -l | tr -d ' ') WAR files."
echo ""

# -------------------------------------------------------
# Build and push Docker image
# -------------------------------------------------------
echo "Building and pushing Docker image..."
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t "$IMAGE" \
  --push \
  "$SCRIPT_DIR/test-backends/"
echo ""
echo "Image pushed: $IMAGE"
