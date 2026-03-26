#!/bin/bash
set -e

DC1_CONTEXT="aks-apim-eus2"
DC2_CONTEXT="aks-apim-wus2"
NAMESPACE="apim"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHART_DIR="$SCRIPT_DIR/chart"

echo "=== SOAP Calculator — Multi-DC Deployment ==="
echo ""
echo "Deploying to both DC1 ($DC1_CONTEXT) and DC2 ($DC2_CONTEXT)"
echo ""

# -------------------------------------------------------
# DC1
# -------------------------------------------------------
echo "--- DC1 ($DC1_CONTEXT) ---"
kubectl config use-context "$DC1_CONTEXT"

if helm status soap-calculator -n "$NAMESPACE" &>/dev/null; then
    echo "soap-calculator already installed on DC1, skipping."
else
    helm install soap-calculator "$CHART_DIR" -n "$NAMESPACE"
fi

echo "Waiting for soap-calculator pod on DC1..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=soap-calculator -n "$NAMESPACE" --timeout=120s
echo "DC1 ready."

# -------------------------------------------------------
# DC2
# -------------------------------------------------------
echo ""
echo "--- DC2 ($DC2_CONTEXT) ---"
kubectl config use-context "$DC2_CONTEXT"

if helm status soap-calculator -n "$NAMESPACE" &>/dev/null; then
    echo "soap-calculator already installed on DC2, skipping."
else
    helm install soap-calculator "$CHART_DIR" -n "$NAMESPACE"
fi

echo "Waiting for soap-calculator pod on DC2..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=soap-calculator -n "$NAMESPACE" --timeout=120s
echo "DC2 ready."

# -------------------------------------------------------
# Summary
# -------------------------------------------------------
echo ""
echo "========================================="
echo "  SOAP Calculator deployed to both DCs"
echo "========================================="
echo ""
echo "WSDL URL (use in Publisher to create SOAP API):"
echo "  http://soap-calculator.apim.svc:8000/?wsdl"
echo ""
echo "Verify WSDL from each cluster:"
echo "  kubectl config use-context $DC1_CONTEXT"
echo "  kubectl exec -n apim \$(kubectl get pod -l app.kubernetes.io/name=soap-calculator -n apim -o jsonpath='{.items[0].metadata.name}') -- curl -s http://localhost:8000/?wsdl | head -5"
echo ""
echo "  kubectl config use-context $DC2_CONTEXT"
echo "  kubectl exec -n apim \$(kubectl get pod -l app.kubernetes.io/name=soap-calculator -n apim -o jsonpath='{.items[0].metadata.name}') -- curl -s http://localhost:8000/?wsdl | head -5"
echo ""
echo "Next: See readme.md for SOAP API testing instructions."
