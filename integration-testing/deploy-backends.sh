#!/bin/bash
set -e

DC1_CONTEXT="aks-apim-eus2"
DC2_CONTEXT="aks-apim-wus2"
NAMESPACE="apim"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Test Backends — Deploy ==="
echo ""

# -------------------------------------------------------
# DC1
# -------------------------------------------------------
echo "--- DC1 ($DC1_CONTEXT) ---"
kubectl config use-context "$DC1_CONTEXT"
kubectl apply -f "$SCRIPT_DIR/test-backends/k8s.yaml"
echo "Waiting for test-backends pod on DC1..."
kubectl wait --for=condition=ready pod -l app=test-backends -n "$NAMESPACE" --timeout=120s
echo "DC1 ready."

# -------------------------------------------------------
# DC2
# -------------------------------------------------------
echo ""
echo "--- DC2 ($DC2_CONTEXT) ---"
kubectl config use-context "$DC2_CONTEXT"
kubectl apply -f "$SCRIPT_DIR/test-backends/k8s.yaml"
echo "Waiting for test-backends pod on DC2..."
kubectl wait --for=condition=ready pod -l app=test-backends -n "$NAMESPACE" --timeout=120s
echo "DC2 ready."

# -------------------------------------------------------
# Summary
# -------------------------------------------------------
echo ""
echo "========================================="
echo "  Test backends deployed to both DCs"
echo "========================================="
echo ""
echo "Service URL (cluster-internal):"
echo "  http://test-backends.apim.svc:8080"
echo ""
echo "Verify from a gateway pod:"
echo "  kubectl -n apim exec deploy/wso2am-gw-deployment -- curl -s http://test-backends.apim.svc:8080/jaxrs_basic/services/customers/customerservice/customers/123"
echo ""
