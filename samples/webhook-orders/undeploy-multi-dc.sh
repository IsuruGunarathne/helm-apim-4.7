#!/bin/bash
set -e

DC1_CONTEXT="aks-apim-eus2"
DC2_CONTEXT="aks-apim-wus2"
NAMESPACE="apim"

echo "=== Webhook Orders — Multi-DC Undeployment ==="
echo ""

# -------------------------------------------------------
# DC1
# -------------------------------------------------------
echo "--- DC1 ($DC1_CONTEXT) ---"
kubectl config use-context "$DC1_CONTEXT"

if helm status webhook-orders -n "$NAMESPACE" &>/dev/null; then
    helm uninstall webhook-orders -n "$NAMESPACE"
    echo "webhook-orders uninstalled from DC1."
else
    echo "webhook-orders not installed on DC1, skipping."
fi

# -------------------------------------------------------
# DC2
# -------------------------------------------------------
echo ""
echo "--- DC2 ($DC2_CONTEXT) ---"
kubectl config use-context "$DC2_CONTEXT"

if helm status webhook-orders -n "$NAMESPACE" &>/dev/null; then
    helm uninstall webhook-orders -n "$NAMESPACE"
    echo "webhook-orders uninstalled from DC2."
else
    echo "webhook-orders not installed on DC2, skipping."
fi

# -------------------------------------------------------
# Summary
# -------------------------------------------------------
echo ""
echo "========================================="
echo "  Webhook Orders removed from both DCs"
echo "========================================="
