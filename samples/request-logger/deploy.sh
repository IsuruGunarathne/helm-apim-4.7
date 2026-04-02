#!/bin/bash
set -e

NAMESPACE="apim"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHART_DIR="$SCRIPT_DIR/chart"

echo "=== Request Logger — Local Deployment ==="
echo ""

# Create namespace if it doesn't exist
kubectl get namespace "$NAMESPACE" &>/dev/null || {
    echo "Creating namespace $NAMESPACE..."
    kubectl create namespace "$NAMESPACE"
}

if helm status request-logger -n "$NAMESPACE" &>/dev/null; then
    echo "request-logger already installed, upgrading..."
    helm upgrade request-logger "$CHART_DIR" -n "$NAMESPACE"
else
    helm install request-logger "$CHART_DIR" -n "$NAMESPACE"
fi

echo "Waiting for request-logger pod..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=request-logger -n "$NAMESPACE" --timeout=120s

echo ""
echo "========================================="
echo "  Request Logger deployed"
echo "========================================="
echo ""
echo "Cluster-internal URL (use as API endpoint in Publisher):"
echo "  http://request-logger.apim.svc:8000"
echo ""
echo "To access locally:"
echo "  kubectl -n $NAMESPACE port-forward svc/request-logger 8000:8000"
echo ""
echo "To follow logs:"
echo "  kubectl logs -n $NAMESPACE deployment/request-logger -f"
