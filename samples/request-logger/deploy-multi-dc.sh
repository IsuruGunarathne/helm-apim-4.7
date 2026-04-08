#!/bin/bash
set -e

DC1_CONTEXT="aks-apim-eus1"
DC2_CONTEXT="aks-apim-wus2"
NAMESPACE="apim"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHART_DIR="$SCRIPT_DIR/chart"

echo "=== Request Logger — Multi-DC Deployment ==="
echo ""
echo "Deploying to both DC1 ($DC1_CONTEXT) and DC2 ($DC2_CONTEXT)"
echo ""

# -------------------------------------------------------
# DC1
# -------------------------------------------------------
echo "--- DC1 ($DC1_CONTEXT) ---"
kubectl config use-context "$DC1_CONTEXT"

if helm status request-logger -n "$NAMESPACE" &>/dev/null; then
    echo "request-logger already installed on DC1, skipping."
else
    helm install request-logger "$CHART_DIR" -n "$NAMESPACE"
fi

echo "Waiting for request-logger pod on DC1..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=request-logger -n "$NAMESPACE" --timeout=120s
echo "DC1 ready."

# -------------------------------------------------------
# DC2
# -------------------------------------------------------
echo ""
echo "--- DC2 ($DC2_CONTEXT) ---"
kubectl config use-context "$DC2_CONTEXT"

if helm status request-logger -n "$NAMESPACE" &>/dev/null; then
    echo "request-logger already installed on DC2, skipping."
else
    helm install request-logger "$CHART_DIR" -n "$NAMESPACE"
fi

echo "Waiting for request-logger pod on DC2..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=request-logger -n "$NAMESPACE" --timeout=120s
echo "DC2 ready."

# -------------------------------------------------------
# Summary
# -------------------------------------------------------
echo ""
echo "========================================="
echo "  Request Logger deployed to both DCs"
echo "========================================="
echo ""
echo "Backend URL (use in Publisher):"
echo "  http://request-logger.apim.svc:8000"
echo ""
echo "Verify from each cluster:"
echo "  kubectl config use-context $DC1_CONTEXT"
echo "  kubectl exec -n apim \$(kubectl get pod -l app.kubernetes.io/name=request-logger -n apim -o jsonpath='{.items[0].metadata.name}') -- curl -s http://localhost:8000/books"
echo ""
echo "  kubectl config use-context $DC2_CONTEXT"
echo "  kubectl exec -n apim \$(kubectl get pod -l app.kubernetes.io/name=request-logger -n apim -o jsonpath='{.items[0].metadata.name}') -- curl -s http://localhost:8000/books"
echo ""
echo "Next: Create a 'Books API' in the Publisher. See MULTI_DC_GUIDE.md for details."
