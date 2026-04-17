#!/bin/bash
set -e

NAMESPACE="apim"
CONTEXT="aks-apim-eus1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== API Platform Gateway — DC1 (East US 1) Deployment ==="
echo "Namespace: $NAMESPACE"
echo "Context:   $CONTEXT"
echo ""

# -------------------------------------------------------
# 0. Switch kubectl context
# -------------------------------------------------------
echo "--- [0] Switching to context $CONTEXT ---"
kubectl config use-context "$CONTEXT"

# -------------------------------------------------------
# 1. Verify Control Plane is running
# -------------------------------------------------------
echo ""
echo "--- [1] Verifying Control Plane is running ---"
if ! kubectl get pods -n "$NAMESPACE" -l deployment=wso2am-cp --field-selector=status.phase=Running 2>/dev/null | grep -q "Running"; then
    echo "ERROR: Control Plane pods are not running in $NAMESPACE."
    echo "Deploy the main APIM stack first: ./scripts/deploy-azure-dc1-mssql.sh"
    exit 1
fi
echo "Control Plane is running."

# -------------------------------------------------------
# 2. Get registration token
# -------------------------------------------------------
echo ""
echo "--- [2] Registration Token ---"
if [ -n "$PLATFORM_GW_TOKEN" ]; then
    TOKEN="$PLATFORM_GW_TOKEN"
    echo "Using token from PLATFORM_GW_TOKEN environment variable."
else
    echo ""
    echo "Before deploying, you need to register a Universal Gateway in the Admin Portal:"
    echo "  1. Go to https://cp.eus1.apim.example.com/admin"
    echo "  2. Navigate to Gateways > Universal Gateways"
    echo "  3. Add a new gateway (type: Universal Gateway)"
    echo "     - Display Name: UGDC1EUS"
    echo "     - URL: https://ug.eus1.apim.example.com"
    echo "     - Visibility: Public"
    echo "  4. Save and copy the registration token"
    echo ""
    read -rp "Enter the registration token: " TOKEN
    if [ -z "$TOKEN" ]; then
        echo "ERROR: Registration token is required."
        exit 1
    fi
fi

# -------------------------------------------------------
# 3. Deploy Platform Gateway
# -------------------------------------------------------
echo ""
echo "--- [3] Deploying Platform Gateway ---"
if helm status platform-gw -n "$NAMESPACE" &>/dev/null; then
    echo "Platform Gateway already installed. Upgrading..."
    helm upgrade platform-gw "$REPO_DIR/distributed/platform-gateway" -n "$NAMESPACE" \
        -f "$REPO_DIR/distributed/platform-gateway/azure-values-dc1.yaml" \
        --set gateway.registrationToken="$TOKEN"
else
    helm install platform-gw "$REPO_DIR/distributed/platform-gateway" -n "$NAMESPACE" \
        -f "$REPO_DIR/distributed/platform-gateway/azure-values-dc1.yaml" \
        --set gateway.registrationToken="$TOKEN"
fi

echo "Waiting for Platform Gateway pods to be ready..."
kubectl wait --for=condition=ready pod -l deployment=wso2am-platform-gw -n "$NAMESPACE" --timeout=300s
echo "Platform Gateway ready."

# -------------------------------------------------------
# Summary
# -------------------------------------------------------
echo ""
echo "========================================="
echo "  Platform Gateway DC1 Deployed"
echo "========================================="
echo ""
kubectl get pods -n "$NAMESPACE" -l deployment=wso2am-platform-gw
echo ""
echo "Endpoint: https://ug.eus1.apim.example.com"
echo ""
echo "Next steps:"
echo "  1. Create a REST API in Publisher with gateway type 'Universal'"
echo "  2. Deploy to the Universal Gateway environment"
echo "  3. Invoke via https://ug.eus1.apim.example.com/<context>/<version>/<resource>"
