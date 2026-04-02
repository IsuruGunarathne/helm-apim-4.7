#!/bin/bash
set -e

DC1_CONTEXT="aks-apim-eus2"
DC2_CONTEXT="aks-apim-wus2"
NAMESPACE="apim"

echo "=== GraphQL Books — Multi-DC Undeployment ==="
echo ""

# -------------------------------------------------------
# DC1
# -------------------------------------------------------
echo "--- DC1 ($DC1_CONTEXT) ---"
kubectl config use-context "$DC1_CONTEXT"

if helm status graphql-books -n "$NAMESPACE" &>/dev/null; then
    helm uninstall graphql-books -n "$NAMESPACE"
    echo "graphql-books uninstalled from DC1."
else
    echo "graphql-books not installed on DC1, skipping."
fi

# -------------------------------------------------------
# DC2
# -------------------------------------------------------
echo ""
echo "--- DC2 ($DC2_CONTEXT) ---"
kubectl config use-context "$DC2_CONTEXT"

if helm status graphql-books -n "$NAMESPACE" &>/dev/null; then
    helm uninstall graphql-books -n "$NAMESPACE"
    echo "graphql-books uninstalled from DC2."
else
    echo "graphql-books not installed on DC2, skipping."
fi

# -------------------------------------------------------
# Summary
# -------------------------------------------------------
echo ""
echo "========================================="
echo "  GraphQL Books removed from both DCs"
echo "========================================="
