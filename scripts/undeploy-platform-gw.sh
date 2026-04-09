#!/bin/bash
set -e

NAMESPACE="apim"
DC1_CONTEXT="aks-apim-eus1"
DC2_CONTEXT="aks-apim-wus2"

echo "=== API Platform Gateway — Undeploy from Both DCs ==="
echo ""

# -------------------------------------------------------
# DC1
# -------------------------------------------------------
echo "--- DC1 ($DC1_CONTEXT) ---"
kubectl config use-context "$DC1_CONTEXT"
if helm status platform-gw -n "$NAMESPACE" &>/dev/null; then
    helm uninstall platform-gw -n "$NAMESPACE"
    echo "Platform Gateway uninstalled from DC1."
else
    echo "Platform Gateway not found on DC1, skipping."
fi

# -------------------------------------------------------
# DC2
# -------------------------------------------------------
echo ""
echo "--- DC2 ($DC2_CONTEXT) ---"
kubectl config use-context "$DC2_CONTEXT"
if helm status platform-gw -n "$NAMESPACE" &>/dev/null; then
    helm uninstall platform-gw -n "$NAMESPACE"
    echo "Platform Gateway uninstalled from DC2."
else
    echo "Platform Gateway not found on DC2, skipping."
fi

echo ""
echo "========================================="
echo "  Platform Gateway undeployed from both DCs"
echo "========================================="
echo ""
echo "Note: Gateway registrations still exist in the Admin Portal."
echo "Remove them manually if no longer needed."
