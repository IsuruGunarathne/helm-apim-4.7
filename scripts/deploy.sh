#!/bin/bash
set -e

NAMESPACE="apim"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== WSO2 APIM 4.7 Distributed Deployment ==="
echo "Namespace: $NAMESPACE"
echo "Repo: $REPO_DIR"
echo ""

# Create namespace if it doesn't exist
kubectl get namespace "$NAMESPACE" &>/dev/null || {
    echo "Creating namespace $NAMESPACE..."
    kubectl create namespace "$NAMESPACE"
}

# 1. Deploy PostgreSQL
echo ""
echo "--- [1/4] Deploying PostgreSQL ---"
helm install postgresql "$REPO_DIR/postgresql" -n "$NAMESPACE" -f "$REPO_DIR/postgresql/values-multi-dc.yaml"

echo "Waiting for PostgreSQL pod..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=postgresql -n "$NAMESPACE" --timeout=120s
echo "PostgreSQL ready (schema init runs as a post-install hook and completes before helm returns)."

# 2. Deploy Control Plane
echo ""
echo "--- [2/4] Deploying Control Plane ---"
helm install cp "$REPO_DIR/distributed/control-plane" -n "$NAMESPACE" -f "$REPO_DIR/distributed/control-plane/local-values-pg.yaml"

echo "Waiting for CP to be ready (this may take a few minutes)..."
kubectl wait --for=condition=ready pod -l deployment=wso2am-cp -n "$NAMESPACE" --timeout=300s
echo "Control Plane ready."

# 3. Deploy Traffic Manager
echo ""
echo "--- [3/4] Deploying Traffic Manager ---"
helm install tm "$REPO_DIR/distributed/traffic-manager" -n "$NAMESPACE" -f "$REPO_DIR/distributed/traffic-manager/local-values-pg.yaml"

echo "Waiting for TM to be ready..."
kubectl wait --for=condition=ready pod -l deployment=wso2am-tm -n "$NAMESPACE" --timeout=300s
echo "Traffic Manager ready."

# 4. Deploy Gateway
echo ""
echo "--- [4/4] Deploying Gateway ---"
helm install gw "$REPO_DIR/distributed/gateway" -n "$NAMESPACE" -f "$REPO_DIR/distributed/gateway/local-values-pg.yaml"

echo "Waiting for GW to be ready..."
kubectl wait --for=condition=ready pod -l deployment=wso2am-gw -n "$NAMESPACE" --timeout=300s
echo "Gateway ready."

# Summary
echo ""
echo "=== Deployment Complete ==="
kubectl get pods -n "$NAMESPACE"
echo ""
echo "To access the services, run in separate terminals:"
echo "  kubectl -n $NAMESPACE port-forward svc/wso2am-cp-service 9443:9443"
echo "  kubectl -n $NAMESPACE port-forward svc/wso2am-gw-service 8243:8243"
echo ""
echo "URLs:"
echo "  Publisher:  https://localhost:9443/publisher"
echo "  DevPortal:  https://localhost:9443/devportal"
echo "  Admin:      https://localhost:9443/admin"
echo "  Gateway:    https://localhost:8243"
echo "  Credentials: admin / admin"
