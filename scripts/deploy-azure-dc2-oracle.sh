#!/bin/bash
set -e

NAMESPACE="apim"
CONTEXT="aks-apim-wus2"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== WSO2 APIM 4.7 — Azure DC2 (West US 2) Deployment [Oracle] ==="
echo "Namespace: $NAMESPACE"
echo "Context:   $CONTEXT"
echo ""

# -------------------------------------------------------
# 0. Switch kubectl context
# -------------------------------------------------------
echo "--- [0] Switching to context $CONTEXT ---"
kubectl config use-context "$CONTEXT"

# -------------------------------------------------------
# 1. Install NGINX Ingress Controller (if not present)
# -------------------------------------------------------
echo ""
echo "--- [1] NGINX Ingress Controller ---"
if helm status ingress-nginx -n ingress-nginx &>/dev/null; then
    echo "NGINX Ingress already installed, skipping."
else
    echo "Installing NGINX Ingress Controller..."
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
    helm repo update
    helm install ingress-nginx ingress-nginx/ingress-nginx \
        --namespace ingress-nginx --create-namespace \
        --set controller.replicaCount=2 \
        --set controller.service.externalTrafficPolicy=Local
fi

echo "Waiting for NGINX external IP..."
for i in $(seq 1 60); do
    INGRESS_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    if [ -n "$INGRESS_IP" ]; then
        echo "NGINX Ingress external IP: $INGRESS_IP"
        break
    fi
    if [ "$i" -eq 60 ]; then
        echo "WARNING: Timed out waiting for NGINX external IP. Continuing anyway..."
    fi
    sleep 5
done

# -------------------------------------------------------
# 2. Create namespace
# -------------------------------------------------------
echo ""
echo "--- [2] Namespace ---"
kubectl get namespace "$NAMESPACE" &>/dev/null || {
    echo "Creating namespace $NAMESPACE..."
    kubectl create namespace "$NAMESPACE"
}

# -------------------------------------------------------
# 3. Create TLS Secret for Ingress
# -------------------------------------------------------
echo ""
echo "--- [3] Creating TLS Secret for Ingress ---"
if kubectl get secret apim-ingress-tls -n "$NAMESPACE" &>/dev/null; then
    echo "TLS secret already exists, skipping."
else
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /tmp/apim-tls.key -out /tmp/apim-tls.crt \
        -subj "/CN=apim.example.com" \
        -addext "subjectAltName=DNS:cp.wus2.apim.example.com,DNS:gw.wus2.apim.example.com,DNS:ug.wus2.apim.example.com" 2>/dev/null
    kubectl create secret tls apim-ingress-tls \
        --cert=/tmp/apim-tls.crt --key=/tmp/apim-tls.key \
        -n "$NAMESPACE"
    rm -f /tmp/apim-tls.key /tmp/apim-tls.crt
    echo "TLS secret created."
fi

# -------------------------------------------------------
# 4. Deploy Control Plane (HA — 2 instances)
# -------------------------------------------------------
echo ""
echo "--- [4/6] Deploying Control Plane (HA) ---"
helm install cp "$REPO_DIR/distributed/control-plane" -n "$NAMESPACE" \
    -f "$REPO_DIR/distributed/control-plane/azure-values-dc2-oracle.yaml"

echo "Waiting for CP instances to be ready (this may take a few minutes)..."
kubectl wait --for=condition=ready pod -l deployment=wso2am-cp -n "$NAMESPACE" --timeout=600s
echo "Control Plane ready."

# -------------------------------------------------------
# 5. Deploy Traffic Manager (HA — 2 instances)
# -------------------------------------------------------
echo ""
echo "--- [5/6] Deploying Traffic Manager (HA) ---"
helm install tm "$REPO_DIR/distributed/traffic-manager" -n "$NAMESPACE" \
    -f "$REPO_DIR/distributed/traffic-manager/azure-values-dc2-oracle.yaml"

echo "Waiting for TM instances to be ready..."
kubectl wait --for=condition=ready pod -l deployment=wso2am-tm -n "$NAMESPACE" --timeout=600s
echo "Traffic Manager ready."

# -------------------------------------------------------
# 6. Deploy Gateway (2 replicas)
# -------------------------------------------------------
echo ""
echo "--- [6/6] Deploying Gateway ---"
helm install gw "$REPO_DIR/distributed/gateway" -n "$NAMESPACE" \
    -f "$REPO_DIR/distributed/gateway/azure-values-dc2-oracle.yaml"

echo "Waiting for GW pods to be ready..."
kubectl wait --for=condition=ready pod -l deployment=wso2am-gw -n "$NAMESPACE" --timeout=600s
echo "Gateway ready."

# -------------------------------------------------------
# 7. Create Internal Load Balancer for cross-DC access
# -------------------------------------------------------
echo ""
echo "--- [7] Creating Internal Load Balancer for CP (cross-DC) ---"
kubectl apply -n "$NAMESPACE" -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: wso2am-cp-ilb
  annotations:
    service.beta.kubernetes.io/azure-load-balancer-internal: "true"
spec:
  type: LoadBalancer
  selector:
    deployment: wso2am-cp
  ports:
    - name: jms
      port: 5672
      targetPort: 5672
EOF

echo "Waiting for ILB IP..."
for i in $(seq 1 60); do
    ILB_IP=$(kubectl get svc wso2am-cp-ilb -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    if [ -n "$ILB_IP" ]; then
        echo "DC2 ILB IP: $ILB_IP"
        break
    fi
    if [ "$i" -eq 60 ]; then
        echo "WARNING: Timed out waiting for ILB IP. Check manually: kubectl get svc wso2am-cp-ilb -n $NAMESPACE"
    fi
    sleep 5
done

# -------------------------------------------------------
# Summary
# -------------------------------------------------------
echo ""
echo "========================================="
echo "  DC2 Deployment Complete [Oracle]"
echo "========================================="
echo ""
kubectl get pods -n "$NAMESPACE"
echo ""
echo "Expected: 6 pods (CP-1, CP-2, TM-1, TM-2, GW-1, GW-2)"
echo ""

echo "TLS Secret:"
kubectl get secret apim-ingress-tls -n "$NAMESPACE" 2>/dev/null && echo "  apim-ingress-tls (OK)" || echo "  (not found)"
echo ""

echo "Ingress:"
kubectl get ingress -n "$NAMESPACE" 2>/dev/null || echo "  (no ingress resources found)"
echo ""

INGRESS_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
ILB_IP=$(kubectl get svc wso2am-cp-ilb -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

echo "IPs:"
echo "  Ingress external IP: ${INGRESS_IP:-<pending>}"
echo "  CP ILB internal IP:  ${ILB_IP:-<pending>}"
echo ""
echo "DNS / /etc/hosts (add these):"
echo "  ${INGRESS_IP:-<INGRESS_IP>}  cp.wus2.apim.example.com  gw.wus2.apim.example.com  ug.wus2.apim.example.com"
echo ""
echo "Endpoints (once DNS is configured):"
echo "  Carbon:     https://cp.wus2.apim.example.com/carbon  (accept cert first!)"
echo "  Publisher:  https://cp.wus2.apim.example.com/publisher"
echo "  DevPortal:  https://cp.wus2.apim.example.com/devportal"
echo "  Admin:      https://cp.wus2.apim.example.com/admin"
echo "  Gateway:    https://gw.wus2.apim.example.com"
echo "  Credentials: admin / admin"
echo ""
echo "Next step: Run ./scripts/setup-cross-dc-oracle.sh (after both DCs are deployed)"
