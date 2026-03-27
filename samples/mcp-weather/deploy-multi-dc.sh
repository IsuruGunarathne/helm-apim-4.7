#!/bin/bash
set -e

DC1_CONTEXT="aks-apim-eus2"
DC2_CONTEXT="aks-apim-wus2"
NAMESPACE="apim"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHART_DIR="$SCRIPT_DIR/chart"

echo "=== MCP Weather Server — Multi-DC Deployment ==="
echo ""
echo "Deploying to both DC1 ($DC1_CONTEXT) and DC2 ($DC2_CONTEXT)"
echo ""

# -------------------------------------------------------
# DC1
# -------------------------------------------------------
echo "--- DC1 ($DC1_CONTEXT) ---"
kubectl config use-context "$DC1_CONTEXT"

if helm status mcp-weather -n "$NAMESPACE" &>/dev/null; then
    echo "mcp-weather already installed on DC1, skipping."
else
    helm install mcp-weather "$CHART_DIR" -n "$NAMESPACE"
fi

echo "Waiting for mcp-weather pod on DC1..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=mcp-weather -n "$NAMESPACE" --timeout=120s
echo "DC1 ready."

# -------------------------------------------------------
# DC2
# -------------------------------------------------------
echo ""
echo "--- DC2 ($DC2_CONTEXT) ---"
kubectl config use-context "$DC2_CONTEXT"

if helm status mcp-weather -n "$NAMESPACE" &>/dev/null; then
    echo "mcp-weather already installed on DC2, skipping."
else
    helm install mcp-weather "$CHART_DIR" -n "$NAMESPACE"
fi

echo "Waiting for mcp-weather pod on DC2..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=mcp-weather -n "$NAMESPACE" --timeout=120s
echo "DC2 ready."

# -------------------------------------------------------
# Summary
# -------------------------------------------------------
echo ""
echo "========================================="
echo "  MCP Weather Server deployed to both DCs"
echo "========================================="
echo ""
echo "MCP SSE endpoint (cluster-internal):"
echo "  http://mcp-weather.apim.svc:8000/sse"
echo ""
echo "Test with port-forward:"
echo "  kubectl -n apim port-forward svc/mcp-weather-mcp-weather 8000:8000"
echo "  Then connect MCP Inspector to http://localhost:8000/sse"
echo ""
