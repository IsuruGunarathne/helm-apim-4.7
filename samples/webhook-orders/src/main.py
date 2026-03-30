import logging
import os
import random
import string
from collections import deque
from datetime import datetime, timezone

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, PlainTextResponse

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)


class HealthCheckFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        return '"GET /health' not in record.getMessage()


logging.getLogger("uvicorn.access").addFilter(HealthCheckFilter())

app = FastAPI(title="Webhook Orders")

HUB_URL = os.getenv("HUB_URL", "")

CUSTOMERS = ["Alice Johnson", "Bob Smith", "Carol White", "David Lee", "Emma Brown"]
SKUS = ["PROD-101", "PROD-202", "PROD-303", "PROD-404", "PROD-505"]
EVENT_TYPES = ["order_created", "order_shipped", "order_delivered"]

deliveries: deque = deque(maxlen=20)


def random_order_id() -> str:
    return "ORD-" + "".join(random.choices(string.digits, k=4))


def generate_event() -> dict:
    qty = random.randint(1, 5)
    price = round(random.uniform(9.99, 99.99), 2)
    sku = random.choice(SKUS)
    return {
        "event": random.choice(EVENT_TYPES),
        "orderId": random_order_id(),
        "customer": random.choice(CUSTOMERS),
        "items": [{"sku": sku, "qty": qty, "price": price}],
        "total": round(qty * price, 2),
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.post("/trigger")
async def trigger():
    event = generate_event()

    if not HUB_URL:
        return JSONResponse(
            status_code=200,
            content={"message": "HUB_URL not configured — event generated but not sent", "event": event},
        )

    topic = f"/{event['event']}"
    url = f"{HUB_URL.rstrip('/')}/webhooks_events_receiver_resource?topic={topic}"
    logger.info("Publishing event to hub | topic=%s url=%s", topic, url)

    async with httpx.AsyncClient(verify=False) as client:
        try:
            resp = await client.post(url, json=event, timeout=10)
            return {"message": "Event sent to hub", "hubStatus": resp.status_code, "topic": topic, "event": event}
        except httpx.RequestError as e:
            return JSONResponse(
                status_code=502,
                content={"message": f"Failed to reach hub: {e}", "event": event},
            )


@app.get("/callback")
async def callback_verify(
    request: Request,
):
    """WebSub subscriber verification of intent — return hub.challenge to confirm subscription."""
    challenge = request.query_params.get("hub.challenge", "")
    topic = request.query_params.get("hub.topic", "")
    mode = request.query_params.get("hub.mode", "")
    logger.info("--- Subscription Verification ---")
    logger.info("  Mode:      %s", mode)
    logger.info("  Topic:     %s", topic)
    logger.info("  Challenge: %s", challenge)
    logger.info("---------------------------------")
    return PlainTextResponse(content=challenge)


@app.post("/callback")
async def callback(request: Request):
    body = await request.json()
    received_at = datetime.now(timezone.utc).isoformat()
    deliveries.append({
        "receivedAt": received_at,
        "headers": dict(request.headers),
        "payload": body,
    })
    logger.info("=== Webhook Delivery Received ===")
    logger.info("  Event:    %s", body.get("event", "unknown"))
    logger.info("  Order:    %s", body.get("orderId", "-"))
    logger.info("  Customer: %s", body.get("customer", "-"))
    logger.info("  Total:    %s", body.get("total", "-"))
    logger.info("  Headers:  %s", {k: v for k, v in request.headers.items() if k.lower() != "authorization"})
    logger.info("  Payload:  %s", body)
    logger.info("=================================")
    return {"status": "received"}


@app.get("/deliveries")
async def get_deliveries():
    return {"count": len(deliveries), "deliveries": list(reversed(deliveries))}
