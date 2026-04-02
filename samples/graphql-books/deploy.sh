#!/bin/bash
set -e

NAMESPACE="apim"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHART_DIR="$SCRIPT_DIR/chart"

echo "=== GraphQL Books — Local Deployment ==="
echo ""

# Create namespace if it doesn't exist
kubectl get namespace "$NAMESPACE" &>/dev/null || {
    echo "Creating namespace $NAMESPACE..."
    kubectl create namespace "$NAMESPACE"
}

if helm status graphql-books -n "$NAMESPACE" &>/dev/null; then
    echo "graphql-books already installed, upgrading..."
    helm upgrade graphql-books "$CHART_DIR" -n "$NAMESPACE"
else
    helm install graphql-books "$CHART_DIR" -n "$NAMESPACE"
fi

echo "Waiting for graphql-books pod..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=graphql-books -n "$NAMESPACE" --timeout=120s

echo ""
echo "========================================="
echo "  GraphQL Books deployed"
echo "========================================="
echo ""
echo "Cluster-internal URL (use as API endpoint in Publisher):"
echo "  http://graphql-books.apim.svc:8000/graphql"
echo ""
echo "To access locally:"
echo "  kubectl -n $NAMESPACE port-forward svc/graphql-books 8000:8000"
echo ""
echo "To follow logs:"
echo "  kubectl logs -n $NAMESPACE deployment/graphql-books -f"
