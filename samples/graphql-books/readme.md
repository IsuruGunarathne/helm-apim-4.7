# GraphQL Books API

A minimal GraphQL Books API for testing WSO2 API Manager's GraphQL features: schema import,
operation-level security, query depth limiting, and GraphQL subscriptions.

## What is GraphQL?

GraphQL is a query language for APIs where the client specifies exactly what data it needs.
Unlike REST (multiple endpoints, fixed response shape), GraphQL exposes a **single endpoint**
(`/graphql`) and the client sends a query or mutation describing exactly what to fetch or change.

Key concepts:
- **Schema** — defines all available types, queries, and mutations in SDL (Schema Definition Language)
- **Query** — read operation (equivalent to GET in REST)
- **Mutation** — write operation (create / update / delete, equivalent to POST/PUT/DELETE)
- **GraphiQL** — browser-based IDE for exploring and testing a GraphQL API interactively

## Schema

```graphql
type Book {
  id: Int!
  title: String!
  author: String!
  year: Int
}

type Query {
  books: [Book!]!        # list all books
  book(id: Int!): Book   # get a single book by ID
}

type Mutation {
  createBook(title: String!, author: String!, year: Int): Book!
  updateBook(id: Int!, title: String, author: String, year: Int): Book
  deleteBook(id: Int!): Boolean!
}

type Subscription {
  bookAdded: Book!    # fires on createBook
  bookDeleted: Int!   # fires on deleteBook — yields the deleted book's ID
}
```

## Service Details

| Property | Value |
|----------|-------|
| Port | 8000 |
| GraphQL endpoint | `http://graphql-books.apim.svc:8000/graphql` |
| GraphiQL IDE | `http://localhost:8000/graphql` (GET, local only) |
| SDL schema | `http://graphql-books.apim.svc:8000/schema` |
| Health check | `http://graphql-books.apim.svc:8000/health` |

## Run Locally

Two entry points are provided:

| File | Subscriptions | Use when |
|------|--------------|----------|
| `main.py` | Yes (WebSocket) | Local dev / testing subscriptions |
| `main-no-subs.py` | No | Registering with WSO2 APIM (simpler SDL, no WebSocket needed) |

```bash
cd samples/graphql-books/src
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

# With subscriptions
uvicorn main:app --host 0.0.0.0 --port 8000

# Without subscriptions (for APIM integration)
uvicorn main-no-subs:app --host 0.0.0.0 --port 8000
```

Open `http://localhost:8000/graphql` in your browser to use the GraphiQL IDE — you can explore
the schema, run queries, and execute mutations interactively.

### GraphiQL quick-reference

Paste any of these directly into the GraphiQL editor and press the Run button.

| Operation | GraphiQL input |
|-----------|---------------|
| List all books | `{ books { id title author year } }` |
| Get book by ID | `{ book(id: 1) { id title author year } }` |
| Create a book | `mutation { createBook(title: "The Great Gatsby", author: "F. Scott Fitzgerald", year: 1925) { id title author year } }` |
| Update a book | `mutation { updateBook(id: 1, year: 2000) { id title author year } }` |
| Delete a book | `mutation { deleteBook(id: 1) }` |
| Subscribe to new books | `subscription { bookAdded { id title author year } }` |
| Subscribe to deletions | `subscription { bookDeleted }` |

### Testing subscriptions with GraphiQL

Subscriptions use a persistent WebSocket connection — the tab stays open and events arrive in real time.

1. Open **two tabs** at `http://localhost:8000/graphql`
2. **Tab 1** — paste and run: `subscription { bookAdded { id title author year } }`
   The spinner indicates it's waiting for events.
3. **Tab 2** — run a `createBook` mutation
4. **Tab 1** immediately receives the new book pushed from the server

To test `bookDeleted`, subscribe in one tab and run `mutation { deleteBook(id: 1) }` in the other.

## Sample Operations

All GraphQL requests are `POST` to `/graphql` with a JSON body containing a `query` field.

### List all books

```bash
curl -s -X POST http://localhost:8000/graphql \
  -H "Content-Type: application/json" \
  -d '{"query": "{ books { id title author year } }"}'
```

### Get a single book

```bash
curl -s -X POST http://localhost:8000/graphql \
  -H "Content-Type: application/json" \
  -d '{"query": "{ book(id: 1) { id title author year } }"}'
```

### Create a book

```bash
curl -s -X POST http://localhost:8000/graphql \
  -H "Content-Type: application/json" \
  -d '{
    "query": "mutation { createBook(title: \"The Great Gatsby\", author: \"F. Scott Fitzgerald\", year: 1925) { id title author year } }"
  }'
```

### Update a book (partial — omit fields you don't want to change)

```bash
curl -s -X POST http://localhost:8000/graphql \
  -H "Content-Type: application/json" \
  -d '{"query": "mutation { updateBook(id: 1, year: 2000) { id title author year } }"}'
```

### Delete a book

```bash
curl -s -X POST http://localhost:8000/graphql \
  -H "Content-Type: application/json" \
  -d '{"query": "mutation { deleteBook(id: 1) }"}'
```

### Get the SDL schema (for APIM registration)

```bash
curl http://localhost:8000/schema
```

---

## Deploy (local Kubernetes)

```bash
./samples/graphql-books/deploy.sh
```

Then port-forward to test:
```bash
kubectl -n apim port-forward svc/graphql-books 8000:8000
```

## Deploy (Multi-DC)

```bash
./samples/graphql-books/deploy-multi-dc.sh
```

---

## Register in WSO2 APIM

### 1. Get the SDL schema

With the service running (locally or via port-forward):
```bash
curl http://localhost:8000/schema > books.graphql
```

### 2. Create the GraphQL API in Publisher

1. Open Publisher: `https://cp.eus1.apim.example.com/publisher` (admin / admin)
2. Click **Create API** > **Import GraphQL SDL**
3. Upload the `books.graphql` file downloaded above
4. Set:
   - Name: `GraphQL Books`
   - Context: `/graphqlbooks`
   - Version: `1.0.0`
5. Set the endpoint: `http://graphql-books.apim.svc:8000/graphql`
6. Go to **Deployments** > **Deploy**
7. Go to **Lifecycle** > **Publish**

### 3. Operation-level security (optional)

In the Publisher, go to **Operations** to see all queries and mutations listed individually.
You can set different throttling tiers or security settings per operation.

---

## Test through Gateway

### Get a token

In DevPortal, subscribe to the **GraphQL Books** API, create an app, generate production keys,
and copy the access token.

### Send a query through the gateway

```bash
curl -sk -X POST https://gw.eus1.apim.example.com/graphqlbooks/1.0.0/graphql \
  -H "Authorization: Bearer <TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{"query": "{ books { id title author year } }"}'
```

### Send a mutation through the gateway

```bash
curl -sk -X POST https://gw.eus1.apim.example.com/graphqlbooks/1.0.0/graphql \
  -H "Authorization: Bearer <TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{
    "query": "mutation { createBook(title: \"1984\", author: \"George Orwell\", year: 1949) { id title } }"
  }'
```

---

## Teardown

```bash
# Local
helm uninstall graphql-books -n apim

# Multi-DC
./samples/graphql-books/undeploy-multi-dc.sh
```
