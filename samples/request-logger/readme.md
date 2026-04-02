# Request Logger

A simple Book CRUD API that logs all incoming requests. Used as a backend for testing APIs through the WSO2 API Gateway.

## Run Locally

```bash
cd samples/request-logger/src
python3 -m venv .venv
source .venv/bin/activate
pip3 install -r requirements.txt
uvicorn main:app --host 0.0.0.0 --port 8000
```
The API will be available at `http://localhost:8000`.

## Deploy

```bash
helm install request-logger ./samples/request-logger/chart -n apim
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=request-logger -n apim --timeout=60s
```

Reachable from within the cluster at:
```
http://request-logger.apim.svc:8000
```

## Sample Requests (direct)

These hit the service directly (useful for verifying the backend works before routing through the gateway).

```bash
# List all books (empty initially)
curl -s http://localhost:8000/books

# Create a book
curl -s -X POST http://localhost:8000/books \
  -H "Content-Type: application/json" \
  -d '{"title": "The Great Gatsby", "author": "F. Scott Fitzgerald", "year": 1925}'

# Create another book
curl -s -X POST http://localhost:8000/books \
  -H "Content-Type: application/json" \
  -d '{"title": "1984", "author": "George Orwell", "year": 1949}'

# List all books
curl -s http://localhost:8000/books

# Update a book (partial update)
curl -s -X PUT http://localhost:8000/books/1 \
  -H "Content-Type: application/json" \
  -d '{"year": 2000}'

# Delete a book
curl -s -X DELETE http://localhost:8000/books/1

# Get OpenAPI spec
curl -s http://localhost:8000/openapi.yaml
```

To port-forward for direct access:
```bash
kubectl -n apim port-forward svc/request-logger 8000:8000
```

## Sample Requests (through API Gateway)

Set the API production endpoint in Publisher to `http://request-logger.apim.svc:8000`, define matching resources (`/books`, `/books/{bookId}`), and deploy the API.

```bash
# List all books
curl -k https://localhost:8243/your-api/1.0.0/books \
  -H "Internal-Key: <your-token>"

# Create a book
curl -k -X POST https://localhost:8243/your-api/1.0.0/books \
  -H "Internal-Key: <your-token>" \
  -H "Content-Type: application/json" \
  -d '{"title": "The Great Gatsby", "author": "F. Scott Fitzgerald", "year": 1925}'

# Update a book
curl -k -X PUT https://localhost:8243/your-api/1.0.0/books/1 \
  -H "Internal-Key: <your-token>" \
  -H "Content-Type: application/json" \
  -d '{"year": 2000}'

# Delete a book
curl -k -X DELETE https://localhost:8243/your-api/1.0.0/books/1 \
  -H "Internal-Key: <your-token>"
```

## Anthropic API Proxy

The service also proxies all requests under `/v1/*` to `https://api.anthropic.com`, logging both the request and response bodies. This lets you point any Anthropic SDK client at the cluster-internal URL to observe traffic without changing your code.

Point the Anthropic SDK at the proxy by overriding `base_url`:

```python
import anthropic

client = anthropic.Anthropic(
    api_key="sk-ant-...",
    base_url="http://request-logger.apim.svc:8000",
)
```

Or with curl directly:

```bash
curl -X POST http://localhost:8000/v1/messages \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{"model":"claude-3-haiku-20240307","max_tokens":64,"messages":[{"role":"user","content":"hello"}]}'
```

Check pod logs to see the logged request and response:

```bash
kubectl logs -n apim deployment/request-logger -f
```

## Teardown

```bash
helm uninstall request-logger -n apim
```