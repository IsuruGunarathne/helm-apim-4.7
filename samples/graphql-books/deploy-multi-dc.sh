#!/bin/bash
set -e

DC1_CONTEXT="aks-apim-eus1"
DC2_CONTEXT="aks-apim-wus2"
NAMESPACE="apim"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHART_DIR="$SCRIPT_DIR/chart"

echo "=== GraphQL Books — Multi-DC Deployment ==="
echo ""
echo "Deploying to both DC1 ($DC1_CONTEXT) and DC2 ($DC2_CONTEXT)"
echo ""

# -------------------------------------------------------
# DC1
# -------------------------------------------------------
echo "--- DC1 ($DC1_CONTEXT) ---"
kubectl config use-context "$DC1_CONTEXT"

if helm status graphql-books -n "$NAMESPACE" &>/dev/null; then
    echo "graphql-books already installed on DC1, skipping."
else
    helm install graphql-books "$CHART_DIR" -n "$NAMESPACE"
fi

echo "Waiting for graphql-books pod on DC1..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=graphql-books -n "$NAMESPACE" --timeout=120s
echo "DC1 ready."

# -------------------------------------------------------
# DC2
# -------------------------------------------------------
echo ""
echo "--- DC2 ($DC2_CONTEXT) ---"
kubectl config use-context "$DC2_CONTEXT"

if helm status graphql-books -n "$NAMESPACE" &>/dev/null; then
    echo "graphql-books already installed on DC2, skipping."
else
    helm install graphql-books "$CHART_DIR" -n "$NAMESPACE"
fi

echo "Waiting for graphql-books pod on DC2..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=graphql-books -n "$NAMESPACE" --timeout=120s
echo "DC2 ready."

# -------------------------------------------------------
# Summary
# -------------------------------------------------------
echo ""
echo "========================================="
echo "  GraphQL Books deployed to both DCs"
echo "========================================="
echo ""
echo "GraphQL endpoint (use in Publisher):"
echo "  http://graphql-books.apim.svc:8000/graphql"
echo ""
echo "SDL schema (for APIM API creation):"
echo "  curl http://graphql-books.apim.svc:8000/schema"
echo ""
echo "Verify from each cluster:"
echo "  kubectl config use-context $DC1_CONTEXT"
echo "  kubectl exec -n apim \$(kubectl get pod -l app.kubernetes.io/name=graphql-books -n apim -o jsonpath='{.items[0].metadata.name}') -- curl -s http://localhost:8000/health"
echo ""
echo "  kubectl config use-context $DC2_CONTEXT"
echo "  kubectl exec -n apim \$(kubectl get pod -l app.kubernetes.io/name=graphql-books -n apim -o jsonpath='{.items[0].metadata.name}') -- curl -s http://localhost:8000/health"
echo ""
echo "Next: Create a GraphQL API in the Publisher. See readme.md for details."
