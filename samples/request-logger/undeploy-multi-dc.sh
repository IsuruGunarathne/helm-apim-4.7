#!/bin/bash
set -e

DC1_CONTEXT="aks-apim-eus2"
DC2_CONTEXT="aks-apim-wus2"
NAMESPACE="apim"

echo "=== Request Logger — Multi-DC Undeployment ==="
echo ""

# -------------------------------------------------------
# DC1
# -------------------------------------------------------
echo "--- DC1 ($DC1_CONTEXT) ---"
kubectl config use-context "$DC1_CONTEXT"

if helm status request-logger -n "$NAMESPACE" &>/dev/null; then
    helm uninstall request-logger -n "$NAMESPACE"
    echo "request-logger uninstalled from DC1."
else
    echo "request-logger not installed on DC1, skipping."
fi

# -------------------------------------------------------
# DC2
# -------------------------------------------------------
echo ""
echo "--- DC2 ($DC2_CONTEXT) ---"
kubectl config use-context "$DC2_CONTEXT"

if helm status request-logger -n "$NAMESPACE" &>/dev/null; then
    helm uninstall request-logger -n "$NAMESPACE"
    echo "request-logger uninstalled from DC2."
else
    echo "request-logger not installed on DC2, skipping."
fi

# -------------------------------------------------------
# Summary
# -------------------------------------------------------
echo ""
echo "========================================="
echo "  Request Logger removed from both DCs"
echo "========================================="
