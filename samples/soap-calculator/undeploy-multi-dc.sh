#!/bin/bash
set -e

DC1_CONTEXT="aks-apim-eus1"
DC2_CONTEXT="aks-apim-wus2"
NAMESPACE="apim"

echo "=== SOAP Calculator — Multi-DC Undeployment ==="
echo ""

# -------------------------------------------------------
# DC1
# -------------------------------------------------------
echo "--- DC1 ($DC1_CONTEXT) ---"
kubectl config use-context "$DC1_CONTEXT"

if helm status soap-calculator -n "$NAMESPACE" &>/dev/null; then
    helm uninstall soap-calculator -n "$NAMESPACE"
    echo "soap-calculator uninstalled from DC1."
else
    echo "soap-calculator not installed on DC1, skipping."
fi

# -------------------------------------------------------
# DC2
# -------------------------------------------------------
echo ""
echo "--- DC2 ($DC2_CONTEXT) ---"
kubectl config use-context "$DC2_CONTEXT"

if helm status soap-calculator -n "$NAMESPACE" &>/dev/null; then
    helm uninstall soap-calculator -n "$NAMESPACE"
    echo "soap-calculator uninstalled from DC2."
else
    echo "soap-calculator not installed on DC2, skipping."
fi

# -------------------------------------------------------
# Summary
# -------------------------------------------------------
echo ""
echo "========================================="
echo "  SOAP Calculator removed from both DCs"
echo "========================================="
