#!/bin/bash
set -e

NAMESPACE="apim"

echo "=== WSO2 APIM 4.7 Azure Teardown ==="
echo "Namespace: $NAMESPACE"
echo ""

# Uninstall in reverse order
for release in gw tm cp; do
    if helm status "$release" -n "$NAMESPACE" &>/dev/null; then
        echo "Uninstalling $release..."
        helm uninstall "$release" -n "$NAMESPACE"
    else
        echo "Release $release not found, skipping."
    fi
done

# Clean up cross-DC resources (not managed by Helm)
echo "Cleaning up cross-DC resources..."
kubectl delete svc wso2am-cp-ilb -n "$NAMESPACE" 2>/dev/null || true
kubectl delete configmap cross-dc-publishers -n "$NAMESPACE" 2>/dev/null || true

# Wait for pods to terminate
echo ""
echo "Waiting for pods to terminate..."
kubectl wait --for=delete pods --all -n "$NAMESPACE" --timeout=120s 2>/dev/null || true

# Delete PVCs
echo "Cleaning up PVCs..."
kubectl delete pvc --all -n "$NAMESPACE" 2>/dev/null || true

# Delete namespace
read -p "Delete namespace $NAMESPACE? (y/N): " confirm
if [[ "$confirm" =~ ^[Yy]$ ]]; then
    kubectl delete namespace "$NAMESPACE"
    echo "Namespace deleted."
else
    echo "Namespace kept."
fi

echo ""
echo "=== Teardown Complete ==="
