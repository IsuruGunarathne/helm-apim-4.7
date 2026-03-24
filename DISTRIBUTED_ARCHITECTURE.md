# WSO2 APIM 4.7 Distributed Architecture

## Components

### Control Plane (CP)
The "brain" of the system. Hosts:
- **Publisher** — where API developers create, version, and publish APIs
- **DevPortal** — where app developers discover APIs, subscribe, and get keys
- **Admin Portal** — throttling policies, gateway environments, analytics config
- **Key Manager (embedded)** — issues OAuth2 tokens, validates subscriptions, manages API keys

Exposes port **9443** (management HTTPS) and **5672** (JMS event hub for internal messaging).

### Traffic Manager (TM)
Handles **throttling and rate limiting**. Receives API request events from gateways, evaluates them against throttling policies (defined in CP's Admin Portal), and sends back decisions. Uses Siddhi (a stream processor) to evaluate complex throttling rules in real-time.

### Gateway (GW)
The **runtime data plane** — all API traffic flows through here. Routes incoming API requests to backend services, enforces security (token validation), applies throttling decisions from TM, and handles request/response mediation. Exposes ports **8243** (HTTPS) and **8280** (HTTP).

## How They Interconnect

```
                 API Developer                    App User
                      │                              │
                      ▼                              ▼
               ┌─────────────┐              ┌──────────────┐
               │ Control     │◄─── sync ───►│   Gateway    │
               │ Plane       │  (APIs,keys) │   (8243)     │
               │ (9443)      │              └──────┬───────┘
               └──────┬──────┘                     │
                      │                            │
                      │ throttle policies          │ throttle events
                      ▼                            ▼
               ┌─────────────┐◄──── real-time ────┘
               │  Traffic    │     event stream
               │  Manager    │────► throttle decisions
               └─────────────┘
                      │
               ┌──────┴──────┐
               │ PostgreSQL  │
               │ apim_db     │  ← API metadata, subscriptions, tokens
               │ shared_db   │  ← user store, registry, tenant data
               └─────────────┘
```

## Key Connections

| From | To | Protocol / Port | Purpose |
|------|----|----------------|---------|
| GW → CP | `wso2am-cp-service:9443` | HTTPS | Fetch API definitions, subscription data, key validation, heartbeats |
| GW → TM | via CP event hub (`9611`/`9711`) | TCP/SSL (Thrift) | Publish API request events for throttle evaluation |
| TM → CP | `wso2am-cp-service:9443` | HTTPS | Retrieve throttling policies and key manager configurations |
| CP event hub → GW, TM | `wso2am-cp-1-service:5672` | JMS (AMQP) | Broadcast events: API deploy/undeploy, token revocation, key updates |
| CP, TM → PostgreSQL | `postgresql.apim.svc:5432` | JDBC | Both `apim_db` and `shared_db` |
| GW → PostgreSQL | `postgresql.apim.svc:5432` | JDBC | `shared_db` only |

## Databases

| Database | Used By | Contents |
|----------|---------|----------|
| `apim_db` | CP, TM | API metadata, subscriptions, OAuth tokens, throttling policies |
| `shared_db` | CP, TM, GW | User store, registry data, tenant information |

## Summary

**CP manages**, **GW routes traffic**, **TM rate-limits**, and they coordinate via REST APIs + JMS events.
