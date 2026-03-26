#!/bin/bash
set -e

NAMESPACE="apim"
DC1_CONTEXT="aks-apim-eus2"
DC2_CONTEXT="aks-apim-wus2"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== WSO2 APIM 4.7 — Cross-DC Event Publisher Setup ==="
echo ""
echo "This script configures cross-DC JMS event publishing between DC1 and DC2."
echo "Both DCs must be fully deployed before running this script."
echo ""

# -------------------------------------------------------
# 1. Get ILB IPs from both DCs
# -------------------------------------------------------
echo "--- [1] Fetching ILB IPs ---"

kubectl config use-context "$DC1_CONTEXT"
DC1_ILB_IP=$(kubectl get svc wso2am-cp-ilb -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
if [ -z "$DC1_ILB_IP" ]; then
    echo "ERROR: DC1 ILB IP not found. Is the wso2am-cp-ilb service running in $DC1_CONTEXT?"
    exit 1
fi
echo "DC1 ILB IP: $DC1_ILB_IP"

kubectl config use-context "$DC2_CONTEXT"
DC2_ILB_IP=$(kubectl get svc wso2am-cp-ilb -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
if [ -z "$DC2_ILB_IP" ]; then
    echo "ERROR: DC2 ILB IP not found. Is the wso2am-cp-ilb service running in $DC2_CONTEXT?"
    exit 1
fi
echo "DC2 ILB IP: $DC2_ILB_IP"
echo ""

# -------------------------------------------------------
# Helper: create cross-dc-publishers ConfigMap
# -------------------------------------------------------
create_configmap() {
    local REMOTE_ILB_IP="$1"

    kubectl create configmap cross-dc-publishers -n "$NAMESPACE" \
      --from-literal=jndi-region2.properties="
connectionfactory.TopicConnectionFactory = amqp://admin:admin@clientid/carbon?brokerlist='tcp://${REMOTE_ILB_IP}:5672'
topic.notification = notification
topic.tokenRevocation = tokenRevocation
topic.keyManager = keyManager
topic.asyncWebhooksData = asyncWebhooksData
topic.throttleData = throttleData
" \
      --from-literal=notificationJMSPublisherRegion2.xml='<?xml version="1.0" encoding="UTF-8"?>
<eventPublisher name="notificationJMSPublisherRegion2" statistics="disable" trace="disable" xmlns="http://wso2.org/carbon/eventpublisher">
  <from streamName="org.wso2.apimgt.notification.stream" version="1.0.0"/>
  <mapping customMapping="disable" type="json"/>
  <to eventAdapterType="jms">
    <property name="java.naming.factory.initial">org.wso2.andes.jndi.PropertiesFileInitialContextFactory</property>
    <property name="java.naming.provider.url">repository/conf/jndi-region2.properties</property>
    <property name="transport.jms.DestinationType">topic</property>
    <property name="transport.jms.Destination">notification</property>
    <property name="transport.jms.ConcurrentPublishers">allow</property>
    <property name="transport.jms.ConnectionFactoryJNDIName">TopicConnectionFactory</property>
  </to>
</eventPublisher>' \
      --from-literal=tokenRevocationJMSPublisherRegion2.xml='<?xml version="1.0" encoding="UTF-8"?>
<eventPublisher name="tokenRevocationJMSPublisherRegion2" statistics="disable" trace="disable" xmlns="http://wso2.org/carbon/eventpublisher">
  <from streamName="org.wso2.apimgt.token.revocation.stream" version="1.0.0"/>
  <mapping customMapping="disable" type="json"/>
  <to eventAdapterType="jms">
    <property name="java.naming.factory.initial">org.wso2.andes.jndi.PropertiesFileInitialContextFactory</property>
    <property name="java.naming.provider.url">repository/conf/jndi-region2.properties</property>
    <property name="transport.jms.DestinationType">topic</property>
    <property name="transport.jms.Destination">tokenRevocation</property>
    <property name="transport.jms.ConcurrentPublishers">allow</property>
    <property name="transport.jms.ConnectionFactoryJNDIName">TopicConnectionFactory</property>
  </to>
</eventPublisher>' \
      --from-literal=keymgtEventJMSEventPublisherRegion2.xml='<?xml version="1.0" encoding="UTF-8"?>
<eventPublisher name="keymgtEventJMSEventPublisherRegion2" statistics="disable" trace="disable" xmlns="http://wso2.org/carbon/eventpublisher">
  <from streamName="org.wso2.apimgt.keymgt.stream" version="1.0.0"/>
  <mapping customMapping="disable" type="json"/>
  <to eventAdapterType="jms">
    <property name="java.naming.factory.initial">org.wso2.andes.jndi.PropertiesFileInitialContextFactory</property>
    <property name="java.naming.provider.url">repository/conf/jndi-region2.properties</property>
    <property name="transport.jms.DestinationType">topic</property>
    <property name="transport.jms.Destination">keyManager</property>
    <property name="transport.jms.ConcurrentPublishers">allow</property>
    <property name="transport.jms.ConnectionFactoryJNDIName">TopicConnectionFactory</property>
  </to>
</eventPublisher>' \
      --from-literal=blockingEventJMSPublisherRegion2.xml='<?xml version="1.0" encoding="UTF-8"?>
<eventPublisher name="blockingEventJMSPublisherRegion2" statistics="disable" trace="disable" xmlns="http://wso2.org/carbon/eventpublisher">
  <from streamName="org.wso2.blocking.request.stream" version="1.0.0"/>
  <mapping customMapping="disable" type="json"/>
  <to eventAdapterType="jms">
    <property name="java.naming.factory.initial">org.wso2.andes.jndi.PropertiesFileInitialContextFactory</property>
    <property name="java.naming.provider.url">repository/conf/jndi-region2.properties</property>
    <property name="transport.jms.DestinationType">topic</property>
    <property name="transport.jms.Destination">throttleData</property>
    <property name="transport.jms.ConcurrentPublishers">allow</property>
    <property name="transport.jms.ConnectionFactoryJNDIName">TopicConnectionFactory</property>
  </to>
</eventPublisher>' \
      --from-literal=asyncWebhooksEventPublisherRegion2.xml='<?xml version="1.0" encoding="UTF-8"?>
<eventPublisher name="asyncWebhooksEventPublisher-1.0.0-Region2" statistics="disable" processing="disable" trace="disable" xmlns="http://wso2.org/carbon/eventpublisher">
  <from streamName="org.wso2.apimgt.webhooks.request.stream" version="1.0.0"/>
  <mapping customMapping="disable" type="json"/>
  <to eventAdapterType="jms">
    <property name="java.naming.factory.initial">org.wso2.andes.jndi.PropertiesFileInitialContextFactory</property>
    <property name="java.naming.provider.url">repository/conf/jndi-region2.properties</property>
    <property name="transport.jms.DestinationType">topic</property>
    <property name="transport.jms.Destination">asyncWebhooksData</property>
    <property name="transport.jms.ConcurrentPublishers">allow</property>
    <property name="transport.jms.ConnectionFactoryJNDIName">TopicConnectionFactory</property>
  </to>
</eventPublisher>'
}

# -------------------------------------------------------
# Helper: helm upgrade CP to mount event publishers
# -------------------------------------------------------
upgrade_cp() {
    local VALUES_FILE="$1"

    helm upgrade cp "$REPO_DIR/distributed/control-plane" -n "$NAMESPACE" \
        -f "$VALUES_FILE" \
        --set-json 'kubernetes.extraVolumes=[{"name":"postgresql-driver-vol","emptyDir":{}},{"name":"cross-dc-publishers","configMap":{"name":"cross-dc-publishers"}}]' \
        --set-json 'kubernetes.extraVolumeMounts=[{"name":"postgresql-driver-vol","mountPath":"/home/wso2carbon/wso2am-acp-4.7.0-alpha/repository/components/lib/postgresql-42.7.4.jar","subPath":"postgresql-42.7.4.jar","readOnly":true},{"name":"cross-dc-publishers","mountPath":"/home/wso2carbon/wso2am-acp-4.7.0-alpha/repository/deployment/server/eventpublishers/notificationJMSPublisherRegion2.xml","subPath":"notificationJMSPublisherRegion2.xml"},{"name":"cross-dc-publishers","mountPath":"/home/wso2carbon/wso2am-acp-4.7.0-alpha/repository/deployment/server/eventpublishers/tokenRevocationJMSPublisherRegion2.xml","subPath":"tokenRevocationJMSPublisherRegion2.xml"},{"name":"cross-dc-publishers","mountPath":"/home/wso2carbon/wso2am-acp-4.7.0-alpha/repository/deployment/server/eventpublishers/keymgtEventJMSEventPublisherRegion2.xml","subPath":"keymgtEventJMSEventPublisherRegion2.xml"},{"name":"cross-dc-publishers","mountPath":"/home/wso2carbon/wso2am-acp-4.7.0-alpha/repository/deployment/server/eventpublishers/blockingEventJMSPublisherRegion2.xml","subPath":"blockingEventJMSPublisherRegion2.xml"},{"name":"cross-dc-publishers","mountPath":"/home/wso2carbon/wso2am-acp-4.7.0-alpha/repository/deployment/server/eventpublishers/asyncWebhooksEventPublisherRegion2.xml","subPath":"asyncWebhooksEventPublisherRegion2.xml"},{"name":"cross-dc-publishers","mountPath":"/home/wso2carbon/wso2am-acp-4.7.0-alpha/repository/conf/jndi-region2.properties","subPath":"jndi-region2.properties"}]'
}

# -------------------------------------------------------
# 2. Configure DC1 → DC2 event publishing
# -------------------------------------------------------
echo "--- [2] Configuring DC1 to publish events to DC2 (ILB: $DC2_ILB_IP) ---"
kubectl config use-context "$DC1_CONTEXT"

# Delete existing ConfigMap if present (for re-runs)
kubectl delete configmap cross-dc-publishers -n "$NAMESPACE" 2>/dev/null || true

create_configmap "$DC2_ILB_IP"
echo "ConfigMap created on DC1."

echo "Upgrading CP on DC1 to mount event publishers..."
upgrade_cp "$REPO_DIR/distributed/control-plane/azure-values-dc1.yaml"
echo "CP upgrade triggered on DC1."

# -------------------------------------------------------
# 3. Configure DC2 → DC1 event publishing
# -------------------------------------------------------
echo ""
echo "--- [3] Configuring DC2 to publish events to DC1 (ILB: $DC1_ILB_IP) ---"
kubectl config use-context "$DC2_CONTEXT"

# Delete existing ConfigMap if present (for re-runs)
kubectl delete configmap cross-dc-publishers -n "$NAMESPACE" 2>/dev/null || true

create_configmap "$DC1_ILB_IP"
echo "ConfigMap created on DC2."

echo "Upgrading CP on DC2 to mount event publishers..."
upgrade_cp "$REPO_DIR/distributed/control-plane/azure-values-dc2.yaml"
echo "CP upgrade triggered on DC2."

# -------------------------------------------------------
# 4. Wait for CP pods to restart in both DCs
# -------------------------------------------------------
echo ""
echo "--- [4] Waiting for CP pods to restart ---"

echo "Waiting for DC1 CP pods..."
kubectl config use-context "$DC1_CONTEXT"
kubectl wait --for=condition=ready pod -l deployment=wso2am-cp -n "$NAMESPACE" --timeout=600s
echo "DC1 CP ready."

echo "Waiting for DC2 CP pods..."
kubectl config use-context "$DC2_CONTEXT"
kubectl wait --for=condition=ready pod -l deployment=wso2am-cp -n "$NAMESPACE" --timeout=600s
echo "DC2 CP ready."

# -------------------------------------------------------
# Summary
# -------------------------------------------------------
echo ""
echo "========================================="
echo "  Cross-DC Event Publishing Configured"
echo "========================================="
echo ""
echo "DC1 ($DC1_CONTEXT) → publishes to DC2 ILB: $DC2_ILB_IP:5672"
echo "DC2 ($DC2_CONTEXT) → publishes to DC1 ILB: $DC1_ILB_IP:5672"
echo ""
echo "Verify cross-DC JMS connectivity:"
echo "  # From DC1, test JMS port to DC2"
echo "  kubectl config use-context $DC1_CONTEXT"
echo "  kubectl exec -n apim \$(kubectl get pod -l deployment=wso2am-cp -n apim -o jsonpath='{.items[0].metadata.name}') \\"
echo "    -c wso2am-control-plane -- bash -c 'echo > /dev/tcp/${DC2_ILB_IP}/5672 && echo OK || echo FAIL'"
echo ""
echo "  # From DC2, test JMS port to DC1"
echo "  kubectl config use-context $DC2_CONTEXT"
echo "  kubectl exec -n apim \$(kubectl get pod -l deployment=wso2am-cp -n apim -o jsonpath='{.items[0].metadata.name}') \\"
echo "    -c wso2am-control-plane -- bash -c 'echo > /dev/tcp/${DC1_ILB_IP}/5672 && echo OK || echo FAIL'"
