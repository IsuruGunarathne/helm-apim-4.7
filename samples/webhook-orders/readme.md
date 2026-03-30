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

`HUB_URL` is the APIM WebSub endpoint this server POSTs events to when `/trigger` is called. It flows through the stack like this:

1. **`deploy-multi-dc.sh`** sets it per DC at install time via `--set env.hubUrl=<url>`
2. **Helm** injects it as a `HUB_URL` environment variable into the container
3. **`main.py`** reads it with `os.getenv("HUB_URL", "")`

Update the placeholder values in `deploy-multi-dc.sh` before deploying:

```bash
DC1_HUB_URL="https://websub.eus2.apim.example.com/webhook/notify"
DC2_HUB_URL="https://websub.wus2.apim.example.com/webhook/notify"
```

> The WebSub hub runs on port 8021 of the APIM gateway. The exact URL depends on your ingress setup. If no dedicated websub ingress exists, use `https://gw.eus2.apim.example.com:8021/webhook/notify`.

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

### Step 1 — Create a WebHook API

1. Open Publisher: `https://cp.eus2.apim.example.com/publisher`
2. Click **Create API** > **WebHook**
3. Set:
   - Name: `OrderEvents`
   - Context: `/order-events`
   - Version: `1.0.0`
4. Under **Topics**, add topics: `order_created`, `order_shipped`, `order_delivered`
5. Set endpoint: `http://webhook-orders.apim.svc:8000`
6. Deploy and Publish

### Step 2 — Subscribe with the callback URL

1. Open DevPortal: `https://cp.eus2.apim.example.com/devportal`
2. Find **OrderEvents** API > Subscribe
3. When prompted for a callback URL, enter:
   ```
   http://webhook-orders.apim.svc:8000/callback
   ```
4. Select topic(s) and confirm

### Step 3 — Trigger an event

```bash
kubectl -n apim port-forward svc/webhook-orders 8000:8000
curl -X POST http://localhost:8000/trigger
```

### Step 4 — Verify delivery

```bash
curl http://localhost:8000/deliveries
```

You should see the event that APIM forwarded to the callback endpoint.

---

## Teardown

```bash
./samples/webhook-orders/undeploy-multi-dc.sh
```
