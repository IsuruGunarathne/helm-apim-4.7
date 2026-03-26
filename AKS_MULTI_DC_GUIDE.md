# Multi-DC Deployment on AKS — WSO2 API Manager 4.7

Deploy WSO2 APIM 4.7 in distributed HA mode across two Azure regions (East US 2 and West US 2) with bi-directional database replication.

## Architecture

```
          DC1 VNet (East US 2)                                DC2 VNet (West US 2)
    ┌─────────────────────────────────┐                ┌─────────────────────────────────┐
    │                                 │   VNet Peering  │                                 │
    │  ┌─ AKS subnet (x.x.2.0/24) ─┐│◄──────────────►│┌─ AKS subnet (x.x.2.0/24) ─┐  │
    │  │ AKS: aks-apim-eus2         ││                 ││ AKS: aks-apim-wus2         │  │
    │  │                            ││   JMS (5672)    ││                            │  │
    │  │ CP-1 ──┐ wso2am-cp-service ││◄───────────────►││ wso2am-cp-service ┌── CP-1 │  │
    │  │ CP-2 ──┤ (ILB for cross-DC)││                 ││ (ILB for cross-DC)├── CP-2 │  │
    │  │ TM-1 ──┤ wso2am-tm-service ││                 ││ wso2am-tm-service ├── TM-1 │  │
    │  │ TM-2 ──┘                   ││                 ││                   └── TM-2 │  │
    │  │                            ││                 ││                            │  │
    │  │ GW-1 ──┐ wso2am-gw-service ││                 ││ wso2am-gw-service ┌── GW-1 │  │
    │  │ GW-2 ──┘ (NGINX Ingress)   ││                 ││ (NGINX Ingress)   └── GW-2 │  │
    │  └────────────────────────────┘│                 │└────────────────────────────┘  │
    │                                 │                 │                                 │
    │  ┌─ DB subnet (x.x.0.0/24) ──┐│                 │┌─ DB subnet (x.x.0.0/24) ──┐  │
    │  │ apim-4-7-eus2.postgres.    ││  pglogical      ││ apim-4-7-wus2.postgres.    │  │
    │  │ database.azure.com         ││◄───────────────►││ database.azure.com         │  │
    │  │ apim_db + shared_db        ││  bi-directional ││ apim_db + shared_db        │  │
    │  └────────────────────────────┘│                 │└────────────────────────────┘  │
    │                                 │                 │                                 │
    │  ┌─ VM subnet (x.x.1.0/24) ──┐│                 │┌─ VM subnet (x.x.1.0/24) ──┐  │
    │  │ Jump-box VM                ││                 ││ Jump-box VM                │  │
    │  └────────────────────────────┘│                 │└────────────────────────────┘  │
    └─────────────────────────────────┘                └─────────────────────────────────┘
```

**Per region:** 2 CP + 2 TM + 2 GW = 6 APIM pods

## Prerequisites

- Azure CLI (`az`) installed and logged in
- `kubectl` and `helm` v3+ installed
- Database setup completed (see `dbscripts/POSTGRES_PGLOGICAL_GUIDE.md`)
- Resource group: `rg-WSO2-APIM-4.7.0-release-isuruguna`

---

## Part 1: AKS Cluster Setup (better to do this on the Azure portal)

Deploy AKS clusters into the **same VNets** as the PostgreSQL Flexible Servers. This avoids extra VNet peering for DB connectivity and gives lower latency.

### Subnet layout per VNet

| Subnet | CIDR | Purpose |
|--------|------|---------|
| `*.*.0.0/24` | DB delegated subnet | PostgreSQL Flexible Server |
| `*.*.1.0/24` | VM subnet | Jump-box VMs for DB access |
| `*.*.2.0/24` | AKS subnet | AKS node pool |

### 1.1 Create AKS subnets in existing DB VNets

```bash
RG="rg-WSO2-APIM-4.7.0-release-isuruguna"

# Find existing DB VNet names
DC1_VNET_NAME=$(az network vnet list --resource-group $RG --query "[?location=='eastus2'].name" -o tsv)
DC2_VNET_NAME=$(az network vnet list --resource-group $RG --query "[?location=='westus2'].name" -o tsv)

echo "DC1 VNet: $DC1_VNET_NAME"
echo "DC2 VNet: $DC2_VNET_NAME"

# Create AKS subnet in DC1 VNet (x.x.2.0/24)
az network vnet subnet create \
  --resource-group $RG \
  --vnet-name $DC1_VNET_NAME \
  --name aks-subnet \
  --address-prefixes 10.0.2.0/24

# Create AKS subnet in DC2 VNet (x.x.2.0/24)
az network vnet subnet create \
  --resource-group $RG \
  --vnet-name $DC2_VNET_NAME \
  --name aks-subnet \
  --address-prefixes 10.1.2.0/24
```

> **Note:** Adjust the CIDR prefixes (`10.0.2.0/24`, `10.1.2.0/24`) to match your VNet address space. The `.2.0/24` range avoids the DB subnet (`.0.0/24`) and VM subnet (`.1.0/24`).

### 1.2 Create AKS clusters in DB VNets

```bash
# Get subnet IDs
DC1_AKS_SUBNET_ID=$(az network vnet subnet show --resource-group $RG --vnet-name $DC1_VNET_NAME --name aks-subnet --query id -o tsv)
DC2_AKS_SUBNET_ID=$(az network vnet subnet show --resource-group $RG --vnet-name $DC2_VNET_NAME --name aks-subnet --query id -o tsv)

# DC1 — East US 2
az aks create \
  --resource-group $RG \
  --name aks-apim-eus2 \
  --location eastus2 \
  --node-count 3 \
  --node-vm-size Standard_D4s_v3 \
  --network-plugin azure \
  --vnet-subnet-id $DC1_AKS_SUBNET_ID \
  --generate-ssh-keys

# DC2 — West US 2
az aks create \
  --resource-group $RG \
  --name aks-apim-wus2 \
  --location westus2 \
  --node-count 3 \
  --node-vm-size Standard_D4s_v3 \
  --network-plugin azure \
  --vnet-subnet-id $DC2_AKS_SUBNET_ID \
  --generate-ssh-keys
```

> **Node sizing:** Standard_D4s_v3 = 4 vCPU, 16 GiB RAM per node. 3 nodes = 12 vCPU, 48 GiB total — enough for 6 APIM pods at 4Gi request each (24Gi) plus system overhead.
>
> **Why same VNet?** AKS pods can reach the PostgreSQL Flexible Server directly (same VNet, no peering needed for DB traffic). Only cross-region VNet peering is needed for DC1↔DC2 JMS communication.

### 1.3 Get credentials

```bash
# DC1
az aks get-credentials --resource-group $RG --name aks-apim-eus2 --context aks-apim-eus2

# DC2
az aks get-credentials --resource-group $RG --name aks-apim-wus2 --context aks-apim-wus2
```

Switch between clusters:
```bash
kubectl config use-context aks-apim-eus2  # DC1
kubectl config use-context aks-apim-wus2  # DC2
```

### 1.4 Install NGINX Ingress Controller

On **both** clusters:
```bash
# DC1
kubectl config use-context aks-apim-eus2
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.replicaCount=2 \
  --set controller.service.externalTrafficPolicy=Local

# DC2
kubectl config use-context aks-apim-wus2
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.replicaCount=2 \
  --set controller.service.externalTrafficPolicy=Local
```

> **Why `externalTrafficPolicy=Local`?** The Azure Load Balancer health probes hit the NGINX NodePort on path `/`. With the default policy (`Cluster`), NGINX returns `404` for `/` (no matching Host header), the LB marks all backends unhealthy, and silently drops all traffic. `Local` mode exposes a dedicated health check port (`/healthz`) that returns `200`, so the LB correctly detects healthy backends. It also preserves the client's real source IP.

Get the external IPs (for DNS later):
```bash
kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

### 1.5 Open NSG for Ingress Traffic

AKS creates its own NSG in the managed resource group (`MC_*`). Add inbound rules to allow HTTP/HTTPS from the internet:

```bash
# Find the AKS-managed NSG names
DC1_MC_RG=$(az aks show --resource-group $RG --name aks-apim-eus2 --query nodeResourceGroup -o tsv)
DC1_NSG=$(az network nsg list --resource-group $DC1_MC_RG --query '[0].name' -o tsv)

DC2_MC_RG=$(az aks show --resource-group $RG --name aks-apim-wus2 --query nodeResourceGroup -o tsv)
DC2_NSG=$(az network nsg list --resource-group $DC2_MC_RG --query '[0].name' -o tsv)

# DC1 — East US 2
az network nsg rule create --resource-group $DC1_MC_RG --nsg-name $DC1_NSG --name AllowHTTPS --priority 100 --direction Inbound --access Allow --protocol TCP --destination-port-ranges 80 443 --source-address-prefixes Internet

# DC2 — West US 2
az network nsg rule create --resource-group $DC2_MC_RG --nsg-name $DC2_NSG --name AllowHTTPS --priority 100 --direction Inbound --access Allow --protocol TCP --destination-port-ranges 80 443 --source-address-prefixes Internet
```

> **Important:** The NSG must be the one in the AKS managed resource group (`MC_*`), not the VNet's NSG. AKS attaches its own NSG (`aks-agentpool-*`) to the subnet. Adding rules to a different NSG has no effect.

### 1.6 VNet Peering (for cross-DC communication)

Since AKS clusters are deployed into the existing DB VNets, peering these VNets enables both cross-DC JMS communication **and** cross-region DB replication (pglogical) over a single peering link.

```bash
# Get VNet resource IDs (same VNets as the databases)
DC1_VNET_ID=$(az network vnet show --resource-group $RG --name $DC1_VNET_NAME --query id -o tsv)
DC2_VNET_ID=$(az network vnet show --resource-group $RG --name $DC2_VNET_NAME --query id -o tsv)

# Create peering DC1 → DC2
az network vnet peering create \
  --name eus2-to-wus2 \
  --resource-group $RG \
  --vnet-name $DC1_VNET_NAME \
  --remote-vnet $DC2_VNET_ID \
  --allow-vnet-access

# Create peering DC2 → DC1
az network vnet peering create \
  --name wus2-to-eus2 \
  --resource-group $RG \
  --vnet-name $DC2_VNET_NAME \
  --remote-vnet $DC1_VNET_ID \
  --allow-vnet-access
```

> **Note:** If VNet peering was already set up for pglogical replication, skip this step — the existing peering already covers AKS-to-AKS cross-DC traffic since the clusters share the same VNets.

---

## Part 2: Database Setup

Already completed. See `dbscripts/POSTGRES_PGLOGICAL_GUIDE.md` for the full setup:
- Azure PostgreSQL Flexible Server in both regions
- DC-specific table scripts with interleaved sequences
- pglogical bi-directional replication active

---

## Part 3: Deploy DC1 (East US 2)

```bash
kubectl config use-context aks-apim-eus2
```

### 3.1 Automated deployment

```bash
./scripts/deploy-azure-dc1.sh
```

### 3.2 Manual deployment (step by step)

```bash
# Create namespace
kubectl create namespace apim

# Deploy Control Plane (HA — 2 instances)
helm install cp ./distributed/control-plane -n apim \
    -f distributed/control-plane/azure-values-dc1.yaml

kubectl wait --for=condition=ready pod -l deployment=wso2am-cp -n apim --timeout=600s

# Deploy Traffic Manager (HA — 2 instances)
helm install tm ./distributed/traffic-manager -n apim \
    -f distributed/traffic-manager/azure-values-dc1.yaml

kubectl wait --for=condition=ready pod -l deployment=wso2am-tm -n apim --timeout=600s

# Deploy Gateway (2 replicas)
helm install gw ./distributed/gateway -n apim \
    -f distributed/gateway/azure-values-dc1.yaml

kubectl wait --for=condition=ready pod -l deployment=wso2am-gw -n apim --timeout=600s
```

### 3.3 Verify DC1

```bash
kubectl get pods -n apim
```

Expected — 6 pods:
```
NAME                                       READY   STATUS    RESTARTS   AGE
wso2am-cp-deployment-1-...                 1/1     Running   0          ...
wso2am-cp-deployment-2-...                 1/1     Running   0          ...
wso2am-tm-deployment-1-...                 1/1     Running   0          ...
wso2am-tm-deployment-2-...                 1/1     Running   0          ...
wso2am-gw-deployment-...-xxx               1/1     Running   0          ...
wso2am-gw-deployment-...-yyy               1/1     Running   0          ...
```

---

## Part 4: Deploy DC2 (West US 2)

```bash
kubectl config use-context aks-apim-wus2
```

### 4.1 Automated deployment

```bash
./scripts/deploy-azure-dc2.sh
```

### 4.2 Manual deployment

Same as DC1 but with `azure-values-dc2.yaml` files:

```bash
kubectl create namespace apim

helm install cp ./distributed/control-plane -n apim \
    -f distributed/control-plane/azure-values-dc2.yaml
kubectl wait --for=condition=ready pod -l deployment=wso2am-cp -n apim --timeout=600s

helm install tm ./distributed/traffic-manager -n apim \
    -f distributed/traffic-manager/azure-values-dc2.yaml
kubectl wait --for=condition=ready pod -l deployment=wso2am-tm -n apim --timeout=600s

helm install gw ./distributed/gateway -n apim \
    -f distributed/gateway/azure-values-dc2.yaml
kubectl wait --for=condition=ready pod -l deployment=wso2am-gw -n apim --timeout=600s
```

---

## Part 4.5: Fix OAuth Callback URLs for DC2

When DC1 starts first, it registers the Publisher and DevPortal as OAuth applications with callback URLs pointing to `cp.eus2.apim.example.com`. These registrations get replicated to DC2 via pglogical. DC2's Publisher/DevPortal will fail to login with **"Registered callback does not match with the provided url"** because the registered callbacks don't include the `wus2` hostname.

**Fix:** Update the OAuth callback URLs to include both DC hostnames.

1. Go to DC2 Carbon: `https://cp.wus2.apim.example.com/carbon` (admin / admin)
2. Navigate to **Identity** > **Service Providers** > **List**
3. Edit `apim_publisher` > **Inbound Authentication Configuration** > **OAuth/OpenID Connect Configuration** > **Edit**
4. Update the **Callback Url** to:
   ```
   regexp=(https://cp.eus2.apim.example.com/publisher/services/auth/callback/login|https://cp.eus2.apim.example.com/publisher/services/auth/callback/logout|https://cp.wus2.apim.example.com/publisher/services/auth/callback/login|https://cp.wus2.apim.example.com/publisher/services/auth/callback/logout)
   ```
5. Click **Update**
6. Edit `apim_devportal` and update its **Callback Url** to:
   ```
   regexp=(https://cp.eus2.apim.example.com/devportal/services/auth/callback/login|https://cp.eus2.apim.example.com/devportal/services/auth/callback/logout|https://cp.wus2.apim.example.com/devportal/services/auth/callback/login|https://cp.wus2.apim.example.com/devportal/services/auth/callback/logout)
   ```
7. Click **Update**

DC2's Publisher and DevPortal login should now work.

> **Note:** This only needs to be done once. The updated callback URLs are stored in `apim_db` and will persist across pod restarts.

---

## Part 5: Cross-DC Event Communication

Each Control Plane needs to publish events (API deploy/undeploy, token revocation, key updates) to the remote region's CP. This uses JMS over port 5672.

**Automated:** Run `./scripts/setup-cross-dc.sh` after both DCs are deployed — it handles steps 5.1–5.3 automatically. The manual steps below are for reference.

### 5.1 Create Internal Load Balancer services

Apply on **DC1** (expose CP for DC2 to reach):
```bash
kubectl config use-context aks-apim-eus2
kubectl apply -n apim -f - <<'EOF'
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
    - name: binary
      port: 9611
      targetPort: 9611
    - name: binary-secure
      port: 9711
      targetPort: 9711
    - name: https
      port: 9443
      targetPort: 9443
EOF
```

Apply on **DC2** (expose CP for DC1 to reach):
```bash
kubectl config use-context aks-apim-wus2
kubectl apply -n apim -f - <<'EOF'
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
    - name: binary
      port: 9611
      targetPort: 9611
    - name: binary-secure
      port: 9711
      targetPort: 9711
    - name: https
      port: 9443
      targetPort: 9443
EOF
```

Get the ILB IPs:
```bash
# DC1 ILB IP (this IP will be used in DC2's event publishers)
kubectl config use-context aks-apim-eus2
kubectl get svc wso2am-cp-ilb -n apim -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
# Example: 10.224.0.100

# DC2 ILB IP (this IP will be used in DC1's event publishers)
kubectl config use-context aks-apim-wus2
kubectl get svc wso2am-cp-ilb -n apim -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
# Example: 10.225.0.100
```

### 5.2 Create event publisher ConfigMaps

Each CP needs 5 JMS event publisher XML files + 1 JNDI properties file pointing to the remote region's CP ILB IP.

Replace `<DC2_ILB_IP>` with the actual ILB IP from DC2, then apply on **DC1**:

```bash
kubectl config use-context aks-apim-eus2

DC2_ILB_IP="<DC2_ILB_IP>"  # Replace with actual IP from step 5.1

kubectl create configmap cross-dc-publishers -n apim \
  --from-literal=jndi-region2.properties="
connectionfactory.TopicConnectionFactory = amqp://admin:admin@clientid/carbon?brokerlist='tcp://${DC2_ILB_IP}:5672'
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
```

Repeat the same on **DC2** (switch context, use `DC1_ILB_IP` instead).

### 5.3 Mount event publishers into CP pods

Upgrade the CP helm release to add the ConfigMap volumes. Add these to the `azure-values-dc1.yaml` (or pass via `--set`):

```bash
kubectl config use-context aks-apim-eus2

helm upgrade cp ./distributed/control-plane -n apim \
    -f distributed/control-plane/azure-values-dc1.yaml \
    --set-json 'kubernetes.extraVolumes=[{"name":"postgresql-driver-vol","emptyDir":{}},{"name":"cross-dc-publishers","configMap":{"name":"cross-dc-publishers"}}]' \
    --set-json 'kubernetes.extraVolumeMounts=[{"name":"postgresql-driver-vol","mountPath":"/home/wso2carbon/wso2am-acp-4.7.0-alpha/repository/components/lib/postgresql-42.7.4.jar","subPath":"postgresql-42.7.4.jar","readOnly":true},{"name":"cross-dc-publishers","mountPath":"/home/wso2carbon/wso2am-acp-4.7.0-alpha/repository/deployment/server/eventpublishers/notificationJMSPublisherRegion2.xml","subPath":"notificationJMSPublisherRegion2.xml"},{"name":"cross-dc-publishers","mountPath":"/home/wso2carbon/wso2am-acp-4.7.0-alpha/repository/deployment/server/eventpublishers/tokenRevocationJMSPublisherRegion2.xml","subPath":"tokenRevocationJMSPublisherRegion2.xml"},{"name":"cross-dc-publishers","mountPath":"/home/wso2carbon/wso2am-acp-4.7.0-alpha/repository/deployment/server/eventpublishers/keymgtEventJMSEventPublisherRegion2.xml","subPath":"keymgtEventJMSEventPublisherRegion2.xml"},{"name":"cross-dc-publishers","mountPath":"/home/wso2carbon/wso2am-acp-4.7.0-alpha/repository/deployment/server/eventpublishers/blockingEventJMSPublisherRegion2.xml","subPath":"blockingEventJMSPublisherRegion2.xml"},{"name":"cross-dc-publishers","mountPath":"/home/wso2carbon/wso2am-acp-4.7.0-alpha/repository/deployment/server/eventpublishers/asyncWebhooksEventPublisherRegion2.xml","subPath":"asyncWebhooksEventPublisherRegion2.xml"},{"name":"cross-dc-publishers","mountPath":"/home/wso2carbon/wso2am-acp-4.7.0-alpha/repository/conf/jndi-region2.properties","subPath":"jndi-region2.properties"}]'
```

Repeat on DC2 with the DC2 values file.

```bash
kubectl config use-context aks-apim-wus2

helm upgrade cp ./distributed/control-plane -n apim \
    -f distributed/control-plane/azure-values-dc2.yaml \
    --set-json 'kubernetes.extraVolumes=[{"name":"postgresql-driver-vol","emptyDir":{}},{"name":"cross-dc-publishers","configMap":{"name":"cross-dc-publishers"}}]' \
    --set-json 'kubernetes.extraVolumeMounts=[{"name":"postgresql-driver-vol","mountPath":"/home/wso2carbon/wso2am-acp-4.7.0-alpha/repository/components/lib/postgresql-42.7.4.jar","subPath":"postgresql-42.7.4.jar","readOnly":true},{"name":"cross-dc-publishers","mountPath":"/home/wso2carbon/wso2am-acp-4.7.0-alpha/repository/deployment/server/eventpublishers/notificationJMSPublisherRegion2.xml","subPath":"notificationJMSPublisherRegion2.xml"},{"name":"cross-dc-publishers","mountPath":"/home/wso2carbon/wso2am-acp-4.7.0-alpha/repository/deployment/server/eventpublishers/tokenRevocationJMSPublisherRegion2.xml","subPath":"tokenRevocationJMSPublisherRegion2.xml"},{"name":"cross-dc-publishers","mountPath":"/home/wso2carbon/wso2am-acp-4.7.0-alpha/repository/deployment/server/eventpublishers/keymgtEventJMSEventPublisherRegion2.xml","subPath":"keymgtEventJMSEventPublisherRegion2.xml"},{"name":"cross-dc-publishers","mountPath":"/home/wso2carbon/wso2am-acp-4.7.0-alpha/repository/deployment/server/eventpublishers/blockingEventJMSPublisherRegion2.xml","subPath":"blockingEventJMSPublisherRegion2.xml"},{"name":"cross-dc-publishers","mountPath":"/home/wso2carbon/wso2am-acp-4.7.0-alpha/repository/deployment/server/eventpublishers/asyncWebhooksEventPublisherRegion2.xml","subPath":"asyncWebhooksEventPublisherRegion2.xml"},{"name":"cross-dc-publishers","mountPath":"/home/wso2carbon/wso2am-acp-4.7.0-alpha/repository/conf/jndi-region2.properties","subPath":"jndi-region2.properties"}]'
```

---

## Part 6: DNS Configuration

Map the ingress external IPs to hostnames. You can use Azure DNS, any DNS provider, or `/etc/hosts` for testing.

```bash
# Get DC1 ingress IP
kubectl config use-context aks-apim-eus2
DC1_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Get DC2 ingress IP
kubectl config use-context aks-apim-wus2
DC2_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

echo "Add to DNS or /etc/hosts:"
echo "$DC1_IP  cp.eus2.apim.example.com  gw.eus2.apim.example.com"
echo "$DC2_IP  cp.wus2.apim.example.com  gw.wus2.apim.example.com"
```

---

## Part 7: Verification

### 7.1 Check pods in both regions

```bash
kubectl config use-context aks-apim-eus2 && kubectl get pods -n apim
kubectl config use-context aks-apim-wus2 && kubectl get pods -n apim
```

### 7.2 Access Publisher and DevPortal

**Via ingress (recommended):** Configure DNS or `/etc/hosts` as described in Part 6, then:

1. Visit `https://cp.eus2.apim.example.com/carbon` — **accept the self-signed certificate first**
2. Visit `https://cp.eus2.apim.example.com/publisher` — login with `admin / admin`
3. Visit `https://cp.eus2.apim.example.com/devportal`

> **Important:** If you skip accepting the certificate at `/carbon`, Publisher and DevPortal will show a "Network Error" fail-whale page because their internal API calls fail the TLS check.

**Via port-forward (fallback):** Note that `proxyPort: 443` is configured in the values files, so the CP generates redirect URLs pointing to port 443. To use port-forward, you must forward from port 443:

```bash
# DC1
kubectl config use-context aks-apim-eus2
sudo kubectl -n apim port-forward svc/wso2am-cp-service 443:9443

# Visit https://localhost/publisher (admin / admin)
# Note: requires sudo since port 443 is privileged
```

### 7.3 Test database replication

Create an API in DC1's Publisher. It should appear in DC2's Publisher within seconds (via database replication).

### 7.4 Test API calls

```bash
# Through DC1 gateway
curl -k https://gw.eus2.apim.example.com/your-api/1.0.0/resource \
  -H "Internal-Key: <token>"

# Through DC2 gateway
curl -k https://gw.wus2.apim.example.com/your-api/1.0.0/resource \
  -H "Internal-Key: <token>"
```

---

## Part 8: Teardown

Per cluster:
```bash
kubectl config use-context aks-apim-eus2  # or aks-apim-wus2
./scripts/undeploy-azure.sh
```

Delete AKS clusters:
```bash
RG="rg-WSO2-APIM-4.7.0-release-isuruguna"
az aks delete --resource-group $RG --name aks-apim-eus2 --yes
az aks delete --resource-group $RG --name aks-apim-wus2 --yes
```

---

## Resource Summary

### Per region

| Component | Instances | CPU Request | CPU Limit | Memory Request/Limit |
|-----------|-----------|-------------|-----------|---------------------|
| Control Plane | 2 | 1500m each | 1800m each | 4Gi each |
| Traffic Manager | 2 | 1500m each | 1800m each | 4Gi each |
| Gateway | 2 | 1500m each | 1800m each | 4Gi each |
| **Total** | **6** | **9000m** | **10800m** | **24Gi** |

### Node pool recommendation

3x Standard_D4s_v3 (4 vCPU, 16 GiB each) = 12 vCPU, 48 GiB per region.

---

## Files Reference

| File | Purpose |
|------|---------|
| `distributed/control-plane/azure-values-dc1.yaml` | CP values for East US 2 |
| `distributed/control-plane/azure-values-dc2.yaml` | CP values for West US 2 |
| `distributed/traffic-manager/azure-values-dc1.yaml` | TM values for East US 2 |
| `distributed/traffic-manager/azure-values-dc2.yaml` | TM values for West US 2 |
| `distributed/gateway/azure-values-dc1.yaml` | GW values for East US 2 |
| `distributed/gateway/azure-values-dc2.yaml` | GW values for West US 2 |
| `scripts/deploy-azure-dc1.sh` | Automated DC1 deployment (NGINX + APIM + ILB) |
| `scripts/deploy-azure-dc2.sh` | Automated DC2 deployment (NGINX + APIM + ILB) |
| `scripts/setup-cross-dc.sh` | Cross-DC event publisher setup (run after both DCs) |
| `scripts/undeploy-azure.sh` | Teardown script |
| `dbscripts/POSTGRES_PGLOGICAL_GUIDE.md` | Database replication setup |
| `dbscripts/dc1/` | DC1 database scripts (sequences start 1, increment 2) |
| `dbscripts/dc2/` | DC2 database scripts (sequences start 2, increment 2) |

## Troubleshooting

### Check pod logs
```bash
kubectl logs -n apim -l deployment=wso2am-cp --tail=50
kubectl logs -n apim -l deployment=wso2am-tm --tail=50
kubectl logs -n apim -l deployment=wso2am-gw --tail=50
```

### Check rendered deployment.toml
```bash
kubectl get configmap -n apim wso2am-cp-conf-1 -o jsonpath='{.data.deployment\.toml}'
```

### Verify database connectivity from a pod
```bash
CP_POD=$(kubectl get pod -l deployment=wso2am-cp -n apim -o jsonpath='{.items[0].metadata.name}')
kubectl exec $CP_POD -n apim -c wso2am-control-plane -- \
  curl -sk https://localhost:9443/carbon/admin/login.jsp | head -5
```

### Check ingress
```bash
kubectl get ingress -n apim
kubectl describe ingress -n apim
```

### 502 Bad Gateway on Publisher/DevPortal login

If you get a 502 on the OAuth callback URL (`/publisher/services/auth/callback/login?code=...`), check the NGINX ingress logs:
```bash
kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller --tail=20 | grep "502\|upstream\|error"
```

If you see `upstream sent too big header while reading response header from upstream`, the `proxy-buffer-size` in the CP ingress annotations is too small. The azure-values files set it to `16k`, which handles WSO2's large OAuth response headers. If you still see this error, increase it further (e.g., `32k`).

### NGINX Ingress unreachable — connection timeout

If the NGINX ingress external IP is assigned but `curl` times out, the Azure Load Balancer may be dropping traffic because health probes are failing.

**Root cause:** With the default `externalTrafficPolicy=Cluster`, Azure LB health probes hit the NGINX NodePort on path `/`. NGINX returns `404` (no matching Host header), the LB treats this as unhealthy, and silently drops all inbound traffic.

**Fix:** Ensure NGINX was installed with `--set controller.service.externalTrafficPolicy=Local` (see step 1.4). If it's already running:
```bash
helm upgrade ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --set controller.replicaCount=2 \
  --set controller.service.externalTrafficPolicy=Local
```

**Verify health probes are working:**
```bash
# Get the healthCheckNodePort
kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.healthCheckNodePort}'

# Test from a node (should return 200)
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
HEALTH_PORT=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.healthCheckNodePort}')
curl -s -o /dev/null -w "%{http_code}" http://$NODE_IP:$HEALTH_PORT/healthz
```

### Cross-DC connectivity test
```bash
# From DC1, test connection to DC2 ILB
kubectl exec -n apim $(kubectl get pod -l deployment=wso2am-cp -n apim -o jsonpath='{.items[0].metadata.name}') \
  -c wso2am-control-plane -- curl -sk https://<DC2_ILB_IP>:9443/services/Version
```
