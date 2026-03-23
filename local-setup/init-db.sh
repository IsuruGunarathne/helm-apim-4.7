#!/bin/bash
# Initialize WSO2 APIM databases in the local MySQL instance.
# Run this AFTER mysql.yaml is deployed and the MySQL pod is ready.

set -euo pipefail

NAMESPACE="apim"
APIM_IMAGE="docker.io/wso2/wso2am:4.7.0-alpha"
APIM_HOME="/home/wso2carbon/wso2am-4.7.0-alpha"
TMP_DIR=$(mktemp -d)

echo "==> Waiting for MySQL pod to be ready..."
kubectl wait --for=condition=ready pod -l app=mysql -n "$NAMESPACE" --timeout=120s

MYSQL_POD=$(kubectl get pod -l app=mysql -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}')
echo "==> MySQL pod: $MYSQL_POD"

echo "==> Starting temporary APIM pod to extract DB scripts..."
kubectl run apim-db-init \
  --image="$APIM_IMAGE" \
  --restart=Never \
  -n "$NAMESPACE" \
  --overrides='{"spec":{"securityContext":{"runAsUser":10001}}}' \
  --command -- sleep 300

echo "==> Waiting for apim-db-init pod to be ready..."
kubectl wait --for=condition=ready pod/apim-db-init -n "$NAMESPACE" --timeout=120s

echo "==> Copying SQL scripts from APIM image..."
kubectl cp "$NAMESPACE/apim-db-init:${APIM_HOME}/dbscripts/apimgt/mysql.sql" "$TMP_DIR/apim_db.sql"
kubectl cp "$NAMESPACE/apim-db-init:${APIM_HOME}/dbscripts/mysql.sql" "$TMP_DIR/shared_db.sql"

echo "==> Cleaning up temporary APIM pod..."
kubectl delete pod apim-db-init -n "$NAMESPACE" --wait=false

echo "==> Copying SQL scripts into MySQL pod..."
kubectl cp "$TMP_DIR/apim_db.sql" "$NAMESPACE/$MYSQL_POD:/tmp/apim_db.sql"
kubectl cp "$TMP_DIR/shared_db.sql" "$NAMESPACE/$MYSQL_POD:/tmp/shared_db.sql"

echo "==> Running APIM DB schema (apim_db)..."
kubectl exec "$MYSQL_POD" -n "$NAMESPACE" -- \
  bash -c "mysql -uroot -proot apim_db < /tmp/apim_db.sql"

echo "==> Running Shared DB schema (shared_db)..."
kubectl exec "$MYSQL_POD" -n "$NAMESPACE" -- \
  bash -c "mysql -uroot -proot shared_db < /tmp/shared_db.sql"

echo "==> Verifying tables..."
kubectl exec "$MYSQL_POD" -n "$NAMESPACE" -- \
  bash -c "mysql -uroot -proot -e 'SELECT COUNT(*) AS apim_tables FROM information_schema.tables WHERE table_schema=\"apim_db\";'"
kubectl exec "$MYSQL_POD" -n "$NAMESPACE" -- \
  bash -c "mysql -uroot -proot -e 'SELECT COUNT(*) AS shared_tables FROM information_schema.tables WHERE table_schema=\"shared_db\";'"

rm -rf "$TMP_DIR"
echo "==> Database initialization complete!"
