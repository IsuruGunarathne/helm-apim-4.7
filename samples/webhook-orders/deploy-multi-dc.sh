#!/bin/bash
set -e

DC1_CONTEXT="aks-apim-eus2"
DC2_CONTEXT="aks-apim-wus2"
NAMESPACE="apim"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHART_DIR="$SCRIPT_DIR/chart"

# APIM WebSub hub endpoint — uses cluster-internal gateway service on websub port 9021
DC1_HUB_URL="http://wso2am-gw-service.apim.svc:9021/order-events/1.0.0"
DC2_HUB_URL="http://wso2am-gw-service.apim.svc:9021/order-events/1.0.0"

echo "=== Webhook Orders — Multi-DC Deployment ==="
echo ""
echo "Deploying to both DC1 ($DC1_CONTEXT) and DC2 ($DC2_CONTEXT)"
echo ""

# -------------------------------------------------------
# DC1
# -------------------------------------------------------
echo "--- DC1 ($DC1_CONTEXT) ---"
kubectl config use-context "$DC1_CONTEXT"

if helm status webhook-orders -n "$NAMESPACE" &>/dev/null; then
    echo "webhook-orders already installed on DC1, skipping."
else
    helm install webhook-orders "$CHART_DIR" -n "$NAMESPACE" \
        --set env.hubUrl="$DC1_HUB_URL"
fi

echo "Waiting for webhook-orders pod on DC1..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=webhook-orders -n "$NAMESPACE" --timeout=120s
echo "DC1 ready."

# -------------------------------------------------------
# DC2
# -------------------------------------------------------
echo ""
echo "--- DC2 ($DC2_CONTEXT) ---"
kubectl config use-context "$DC2_CONTEXT"

if helm status webhook-orders -n "$NAMESPACE" &>/dev/null; then
    echo "webhook-orders already installed on DC2, skipping."
else
    helm install webhook-orders "$CHART_DIR" -n "$NAMESPACE" \
        --set env.hubUrl="$DC2_HUB_URL"
fi

echo "Waiting for webhook-orders pod on DC2..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=webhook-orders -n "$NAMESPACE" --timeout=120s
echo "DC2 ready."

# -------------------------------------------------------
# Summary
# -------------------------------------------------------
echo ""
echo "========================================="
echo "  Webhook Orders deployed to both DCs"
echo "========================================="
echo ""
echo "Backend URL (use in APIM WebHook API):"
echo "  http://webhook-orders.apim.svc:8000"
echo ""
echo "Callback URL (use as subscriber in DevPortal):"
echo "  http://webhook-orders.apim.svc:8000/callback"
echo ""
echo "Test:"
echo "  kubectl -n apim port-forward svc/webhook-orders 8000:8000"
echo "  curl -X POST http://localhost:8000/trigger"
echo "  curl http://localhost:8000/deliveries"
echo ""
