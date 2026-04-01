#!/usr/bin/env bash
# apply-overrides.sh — Copy modified integration test files into product-apim and rebuild
#
# Usage:
#   cd integration-testing
#   ./apply-overrides.sh
#
# This copies the files from product-apim-overrides/ into the correct locations
# under product-apim/all-in-one-apim/ and rebuilds the tests-common module so
# the changes are picked up by the test runner.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OVERRIDES="$SCRIPT_DIR/product-apim-overrides"
TARGET="$SCRIPT_DIR/../product-apim/all-in-one-apim"

if [ ! -d "$OVERRIDES/modules" ]; then
    echo "ERROR: product-apim-overrides/modules not found. Run from integration-testing/."
    exit 1
fi

if [ ! -d "$TARGET/modules" ]; then
    echo "ERROR: product-apim/all-in-one-apim/modules not found."
    echo "Make sure product-apim is checked out at the same level as integration-testing."
    exit 1
fi

echo "==> Copying override files into product-apim..."

# Use rsync to copy preserving directory structure
rsync -av --relative "$OVERRIDES/./modules/" "$TARGET/"

echo ""
echo "==> Rebuilding tests-common (integration-test-utils)..."
cd "$TARGET"
mvn clean install -pl :org.wso2.am.integration.common.test.utils -DskipTests -am -q

echo ""
echo "==> Done. Override files applied and tests-common rebuilt."
echo "    You can now run integration tests with:"
echo "    cd product-apim/all-in-one-apim"
echo '    PRODUCT_APIM_TESTS="apim-integration-tests-api-common" mvn clean install -DplatformTests -Pwithout-restart -pl modules/integration/tests-integration/tests-backend'
