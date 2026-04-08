#!/bin/bash
set -e

DC1_CONTEXT="aks-apim-eus1"
DC2_CONTEXT="aks-apim-wus2"
NAMESPACE="apim"

echo "=== MCP Weather Server — Multi-DC Undeployment ==="
echo ""

# -------------------------------------------------------
# DC1
# -------------------------------------------------------
echo "--- DC1 ($DC1_CONTEXT) ---"
kubectl config use-context "$DC1_CONTEXT"

if helm status mcp-weather -n "$NAMESPACE" &>/dev/null; then
    helm uninstall mcp-weather -n "$NAMESPACE"
    echo "mcp-weather uninstalled from DC1."
else
    echo "mcp-weather not installed on DC1, skipping."
fi

# -------------------------------------------------------
# DC2
# -------------------------------------------------------
echo ""
echo "--- DC2 ($DC2_CONTEXT) ---"
kubectl config use-context "$DC2_CONTEXT"

if helm status mcp-weather -n "$NAMESPACE" &>/dev/null; then
    helm uninstall mcp-weather -n "$NAMESPACE"
    echo "mcp-weather uninstalled from DC2."
else
    echo "mcp-weather not installed on DC2, skipping."
fi

# -------------------------------------------------------
# Summary
# -------------------------------------------------------
echo ""
echo "========================================="
echo "  MCP Weather Server removed from both DCs"
echo "========================================="
