#!/bin/bash
set -e

DC1_CONTEXT="aks-apim-eus1"
DC2_CONTEXT="aks-apim-wus2"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Test Backends — Undeploy ==="
echo ""

echo "--- DC1 ($DC1_CONTEXT) ---"
kubectl config use-context "$DC1_CONTEXT"
kubectl delete -f "$SCRIPT_DIR/test-backends/k8s.yaml" --ignore-not-found
echo "Removed from DC1."

echo ""
echo "--- DC2 ($DC2_CONTEXT) ---"
kubectl config use-context "$DC2_CONTEXT"
kubectl delete -f "$SCRIPT_DIR/test-backends/k8s.yaml" --ignore-not-found
echo "Removed from DC2."

echo ""
echo "========================================="
echo "  Test backends removed from both DCs"
echo "========================================="
