#!/bin/bash
set -e

NAMESPACE="apim"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== WSO2 APIM 4.7 — Azure DC1 (East US 2) Deployment ==="
echo "Namespace: $NAMESPACE"
echo ""

# Create namespace if it doesn't exist
kubectl get namespace "$NAMESPACE" &>/dev/null || {
    echo "Creating namespace $NAMESPACE..."
    kubectl create namespace "$NAMESPACE"
}

# 1. Deploy Control Plane (HA — 2 instances)
echo ""
echo "--- [1/3] Deploying Control Plane (HA) ---"
helm install cp "$REPO_DIR/distributed/control-plane" -n "$NAMESPACE" \
    -f "$REPO_DIR/distributed/control-plane/azure-values-dc1.yaml"

echo "Waiting for CP instances to be ready (this may take a few minutes)..."
kubectl wait --for=condition=ready pod -l deployment=wso2am-cp -n "$NAMESPACE" --timeout=600s
echo "Control Plane ready."

# 2. Deploy Traffic Manager (HA — 2 instances)
echo ""
echo "--- [2/3] Deploying Traffic Manager (HA) ---"
helm install tm "$REPO_DIR/distributed/traffic-manager" -n "$NAMESPACE" \
    -f "$REPO_DIR/distributed/traffic-manager/azure-values-dc1.yaml"

echo "Waiting for TM instances to be ready..."
kubectl wait --for=condition=ready pod -l deployment=wso2am-tm -n "$NAMESPACE" --timeout=600s
echo "Traffic Manager ready."

# 3. Deploy Gateway (2 replicas)
echo ""
echo "--- [3/3] Deploying Gateway ---"
helm install gw "$REPO_DIR/distributed/gateway" -n "$NAMESPACE" \
    -f "$REPO_DIR/distributed/gateway/azure-values-dc1.yaml"

echo "Waiting for GW pods to be ready..."
kubectl wait --for=condition=ready pod -l deployment=wso2am-gw -n "$NAMESPACE" --timeout=600s
echo "Gateway ready."

# Summary
echo ""
echo "=== DC1 Deployment Complete ==="
kubectl get pods -n "$NAMESPACE"
echo ""
echo "Expected: 6 pods (CP-1, CP-2, TM-1, TM-2, GW-1, GW-2)"
echo ""
echo "Ingress endpoints (once DNS is configured):"
echo "  Publisher:  https://cp.eus2.apim.example.com/publisher"
echo "  DevPortal:  https://cp.eus2.apim.example.com/devportal"
echo "  Admin:      https://cp.eus2.apim.example.com/admin"
echo "  Gateway:    https://gw.eus2.apim.example.com"
echo "  Credentials: admin / admin"
