# Webhook Orders

A minimal WebHook/WebSub backend for testing WSO2 API Manager's WebHook API feature. Acts as both an **event publisher** (fires order events to APIM's WebSub hub) and a **subscriber callback** (receives delivered events from APIM).

## What is WebHook/WebSub?

WebSub (W3C standard, formerly PubSubHubbub) is a publish/subscribe protocol over HTTP:

- **Publisher** — backend that generates events and POSTs them to a hub
- **Hub** — intermediary (WSO2 APIM) that receives events and fans them out to subscribers
- **Subscriber** — any HTTP endpoint that wants to receive events; registers a callback URL with the hub

```
[this server /trigger] → event → [APIM WebSub Hub] → [subscribers' callback URLs]
                                                              ↓
                                              [this server /callback] ← logs delivery
```

## Service Details

| Property | Value |
|----------|-------|
| Port | 8000 |
| Backend URL (for APIM) | `http://webhook-orders.apim.svc:8000` |
| Callback URL (subscriber) | `http://webhook-orders.apim.svc:8000/callback` |

## Endpoints

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/health` | Health check |
| POST | `/trigger` | Generate a random order event, POST to APIM hub |
| POST | `/callback` | Receive webhook delivery from APIM, log it |
| GET | `/deliveries` | View last 20 deliveries received |

## Event Payload

```json
{
  "event": "order_created",
  "orderId": "ORD-8472",
  "customer": "Alice Johnson",
  "items": [{"sku": "PROD-202", "qty": 3, "price": 29.99}],
  "total": 89.97,
  "timestamp": "2026-03-27T11:00:00Z"
}
```

Event types: `order_created`, `order_shipped`, `order_delivered` (random).

## Run Locally

```bash
cd samples/webhook-orders/src
python3.12 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn main:app --host 0.0.0.0 --port 8000
```

Test locally (no APIM needed):

```bash
# Trigger an event (no hub configured — event is generated but not sent)
curl -X POST http://localhost:8000/trigger

# Simulate an incoming webhook delivery
curl -X POST http://localhost:8000/callback \
  -H "Content-Type: application/json" \
  -d '{"event":"order_shipped","orderId":"ORD-1234"}'

# View received deliveries
curl http://localhost:8000/deliveries
```

---

## Deploy (Kubernetes)

### Configure the Hub URL

`HUB_URL` is the base APIM WebSub endpoint. When `/trigger` is called, the server appends `/webhooks_events_receiver_resource?topic=/<event_type>` automatically and POSTs the event there.

It flows through the stack like this:

1. **`deploy-multi-dc.sh`** sets it per DC at install time via `--set env.hubUrl=<url>`
2. **Helm** injects it as a `HUB_URL` environment variable into the container
3. **`main.py`** reads it, appends the topic-specific receiver path, and POSTs events

Update the placeholder values in `deploy-multi-dc.sh` before deploying:

```bash
DC1_HUB_URL="http://wso2am-gw-service.apim.svc:9021/order-events/1.0.0"
DC2_HUB_URL="http://wso2am-gw-service.apim.svc:9021/order-events/1.0.0"
```

The full URL that gets called looks like:
```
http://wso2am-gw-service.apim.svc:9021/order-events/1.0.0/webhooks_events_receiver_resource?topic=/order_created
```

> Uses the cluster-internal gateway service (`wso2am-gw-service`) on the WebSub HTTP port (9021). External hostnames like `gw.eus2.apim.example.com` don't resolve from inside pods. The callback URLs shown in the Publisher portal (under **Topics** > expand a topic) show the external equivalent.

If `HUB_URL` is not set, `/trigger` still generates an event but logs a warning instead of sending it — useful for local testing.

Then:

```bash
./samples/webhook-orders/deploy-multi-dc.sh
```

Verify:
```bash
kubectl config use-context aks-apim-eus2
kubectl get pods -n apim -l app.kubernetes.io/name=webhook-orders
```

---

## Test with WSO2 APIM

### Step 1 — Create a WebSub Streaming API (Publisher)

1. Open Publisher: `https://cp.eus2.apim.example.com/publisher`
2. Click **Create API** > **Streaming API** > **WebSub/WebHook API**
3. Fill in:
   - Name: `OrderEvents`
   - Context: `/order-events`
   - Version: `1.0.0`
4. Go to **API Configurations** > **Runtime** and set the endpoint:
   ```
   http://webhook-orders.apim.svc:8000
   ```
5. Go to **API Configurations** > **Topics** and add three topics:

   | Type | Channel Address | Operation Name |
   |------|-----------------|----------------|
   | receive | `/order_created` | `order_created` |
   | receive | `/order_shipped` | `order_shipped` |
   | receive | `/order_delivered` | `order_delivered` |

   For each: fill in Channel Address and Operation Name, then click **`+`** to add the next. Click **Save** when done.

6. (Optional) Expand **Subscription Configuration** on the Topics page > click **Enable** to enable secret generation > select **SHA1** as the signing algorithm > **Generate** a secret. Copy and save it for Step 3.
7. Go to **Portal Configurations** > **Subscriptions** > select the **AsyncWHGold** business plan > **Save**
8. Go to **Lifecycle** > click **Publish**
9. Go to **Deployments** > click **Deploy New Revision** > select **Production and Sandbox** > **Deploy**

### Step 2 — Create Application & Get Access Token (DevPortal)

1. Open DevPortal: `https://cp.eus2.apim.example.com/devportal`
2. Go to **Applications** > **Add New Application** > name it `OrderEventsApp` > **Save**
   (Or use the `DefaultApplication`)
3. Find the **OrderEvents** API > click **Subscribe** > select your application > click **Subscribe**
4. Go to **Applications** > `OrderEventsApp` > **Production Keys** > **Generate Keys**
5. Copy the **Access Token** — you'll need it for the subscribe curl

### Step 3 — Subscribe to a topic via curl

WebSub subscriptions use a POST with `application/x-www-form-urlencoded` hub parameters to the **regular gateway** endpoint (not the websub port):

```bash
curl -sk -X POST 'https://gw.eus2.apim.example.com/order-events/1.0.0' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -H 'Authorization: Bearer eyJ4NXQiOiJWazdLelF1SDh3ZW1uTEx0ZkR4RFBENXFrX1UiLCJraWQiOiJNalF6WldVNE5qTXpZakUxTm1ZeE1HUTFZV1k0WkdNeFpqVXdaV1V6WTJGa1ptTXpNelpoWXpVNU16QmhNMlF6WlRVelpqYzNPVFExTjJJeU5UWmpNd19SUzI1NiIsInR5cCI6ImF0K2p3dCIsImFsZyI6IlJTMjU2In0.eyJzdWIiOiJwVmxvZTVIMXlsZlBWSDRvUXpncndJMEtTbUFhIiwiYXV0IjoiQVBQTElDQVRJT04iLCJpc3MiOiJodHRwczovL2FwaS5hc2dhcmRlby5pby90L2lzdHZlbnRlcnByaXNlcy9vYXV0aDIvdG9rZW4iLCJjbGllbnRfaWQiOiJwVmxvZTVIMXlsZlBWSDRvUXpncndJMEtTbUFhIiwiYXVkIjoicFZsb2U1SDF5bGZQVkg0b1F6Z3J3STBLU21BYSIsIm5iZiI6MTc3NDg1MTE4MCwiYXpwIjoicFZsb2U1SDF5bGZQVkg0b1F6Z3J3STBLU21BYSIsIm9yZ19pZCI6ImJmNmQxOTRmLTk2ZDMtNGUxZC05MTZjLTk3NzcyYWYxMTgwYiIsImV4cCI6MTc3NDg1NDc4MCwib3JnX25hbWUiOiJpc3R2ZW50ZXJwcmlzZXMiLCJpYXQiOjE3NzQ4NTExODAsImp0aSI6IjJjNTBmNmRjLThlNTktNGNiMy1hODNjLTYzOTU5NjgxOThmMyIsIm9yZ19oYW5kbGUiOiJpc3R2ZW50ZXJwcmlzZXMifQ.M0-BnUKq7OTKTnbIaqoGOUcLdciAa2uX1_U6L3E9GICOrwSX-isWRN2uYWZIX5vnD5HGBEa4_l0lRuhdfSeXAb-qPrVwgwo9irzJhSEJeUgzDCgAD5bUOXKxkkfKSPVCXXKkqEe-dlJc1oZ5Vu-_rJ-w7iEVrc7aLJcdEEMsvxd7wZbXQkEm4S2CbvBS2Lg3-rDlrL3MZnCZemH7ijphsdrBzjkO8ldOjyBTI56KQbEU178Cp13XsmNKr69n_rY6bJ8BgIlcdSbHaNpNycQWVBC2qzgSYqxiGwWGwN0lG7zqJATdcTCUO902KhZCiP9BOL47myet_Un-Zx4mQAK6yQ' \
  -d 'hub.topic=/order_created' \
  -d 'hub.callback=http%3A%2F%2Fwebhook-orders.apim.svc%3A8000%2Fcallback' \
  -d 'hub.mode=subscribe' \
  -d 'hub.secret=mysecret' \
  -d 'hub.lease_seconds=50000000'
```

> **Note:** `hub.callback` must be URL-encoded. The value above is `http://webhook-orders.apim.svc:8000/callback` encoded.

> **Quick test alternative:** Use [webhook.site](https://webhook.site) to get a disposable callback URL — URL-encode it and use as `hub.callback` to verify events arrive without needing the callback server.

### Step 4 — Trigger an event

Port-forward and call `/trigger` to generate a random order event and POST it to the hub:

```bash
kubectl -n apim port-forward svc/webhook-orders 8000:8000
curl -X POST http://localhost:8000/trigger
```

The server generates a random order event (e.g., `order_created`) and POSTs it to:
```
{HUB_URL}/webhooks_events_receiver_resource?topic=/order_created
```
APIM receives the event on the websub port and delivers it to all subscribers registered for that topic.

### Step 5 — Verify delivery

Check received deliveries via the API:

```bash
curl http://localhost:8000/deliveries
```

Or watch the pod logs in real time:

```bash
kubectl logs -n apim -l app.kubernetes.io/name=webhook-orders -f
```

You should see the event logged with its order ID, customer, and total as APIM delivers it to the callback.

### Optional — Unsubscribe from a topic

```bash
curl -sk -X POST 'https://gw.eus2.apim.example.com/order-events/1.0.0' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -H 'Authorization: Bearer <ACCESS_TOKEN>' \
  -d 'hub.topic=/order_created' \
  -d 'hub.callback=http%3A%2F%2Fwebhook-orders.apim.svc%3A8000%2Fcallback' \
  -d 'hub.mode=unsubscribe' \
  -d 'hub.secret=mysecret'
```

---

## Teardown

```bash
./samples/webhook-orders/undeploy-multi-dc.sh
```
