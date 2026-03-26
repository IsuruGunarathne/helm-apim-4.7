# SOAP Calculator — Testing SOAP APIs in WSO2 APIM

A minimal SOAP Calculator backend service for testing WSO2 API Manager's SOAP API features: WSDL import, WSDL URL access, restricted visibility, tenant SOAP APIs, and SOAP operations listing.

## What is SOAP?

SOAP (Simple Object Access Protocol) is an XML-based messaging protocol. Unlike REST APIs (which use JSON over HTTP), SOAP APIs use structured XML messages with strict schemas.

Key concepts:
- **WSDL** (Web Services Description Language) — an XML file that describes the SOAP service: what operations are available, what inputs they take, what outputs they return, and where the service endpoint is. Think of it as the SOAP equivalent of an OpenAPI spec.
- **SOAP Envelope** — every request/response is wrapped in an XML envelope with a `<Header>` and `<Body>`.
- **Operations** — the "methods" a SOAP service exposes (like REST endpoints, but defined in the WSDL).

This calculator exposes 4 operations: `Add`, `Subtract`, `Multiply`, `Divide`.

## Service Details

| Property | Value |
|----------|-------|
| Port | 8000 |
| WSDL URL | `http://soap-calculator.apim.svc:8000/?wsdl` |
| SOAP Endpoint | `http://soap-calculator.apim.svc:8000/` |
| Operations | Add, Subtract, Multiply, Divide |

Example SOAP request (Add 5 + 3):
```xml
<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/"
                  xmlns:calc="http://calculator.example.com">
  <soapenv:Body>
    <calc:Add>
      <calc:a>5</calc:a>
      <calc:b>3</calc:b>
    </calc:Add>
  </soapenv:Body>
</soapenv:Envelope>
```

Response:
```xml
<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/"
                  xmlns:calc="http://calculator.example.com">
  <soapenv:Body>
    <calc:AddResponse>
      <calc:AddResult>8</calc:AddResult>
    </calc:AddResponse>
  </soapenv:Body>
</soapenv:Envelope>
```

## Deploy

```bash
./samples/soap-calculator/deploy-multi-dc.sh
```

Verify:
```bash
# DC1
kubectl config use-context aks-apim-eus2
kubectl get pods -n apim -l app.kubernetes.io/name=soap-calculator

# DC2
kubectl config use-context aks-apim-wus2
kubectl get pods -n apim -l app.kubernetes.io/name=soap-calculator
```

---

## Test Scenario 1: WSDL URL Access

### 1.1 Create the SOAP API

1. Open Publisher: `https://cp.eus2.apim.example.com/publisher` (admin / admin)
2. Click **Create API** > **Import WSDL**
3. Select **WSDL URL** and enter: `http://soap-calculator.apim.svc:8000/?wsdl`
4. Click **Next**
5. Set:
   - Name: `Calculator`
   - Context: `/calculator`
   - Version: `1.0.0`
6. Set the endpoint: `http://soap-calculator.apim.svc:8000`
7. Go to **Deployments** > **Deploy**
8. Go to **Lifecycle** > **Publish**

### 1.2 Verify WSDL in DevPortal

1. Open DevPortal: `https://cp.eus2.apim.example.com/devportal`
2. Find the **Calculator** API > click it
3. On the **Overview** page, verify:
   - **Download WSDL** button is available
   - **Copy WSDL URL** button is available
4. Click **Copy WSDL URL**
5. Paste the URL in your browser — it should return WSDL XML
6. Paste the URL in SoapUI > **New SOAP Project** > **Initial WSDL** — the 4 operations should appear

---

## Test Scenario 2: Restricted Visibility + Expiring WSDL URL

### 2.1 Restrict the API

1. In Publisher, go to the **Calculator** API
2. Go to **Portal Configurations** (or **Design** section)
3. Change **Visibility** from `Public` to `Restricted`
4. Select a role (e.g., `Internal/subscriber`) and **Save**

### 2.2 Verify signed WSDL URL

1. In DevPortal, go to the **Calculator** API > **Overview**
2. Click **Copy WSDL URL**
3. Inspect the URL — it should now contain `exp` and `sig` query parameters:
   ```
   https://gw.eus2.apim.example.com/calculator/1.0.0?wsdl&exp=1711234567&sig=abc123...
   ```
4. Paste in browser — it should return the WSDL XML (the signature is still valid)

### 2.3 Verify URL expiry

1. Wait **15 minutes**
2. Paste the same URL again — it should return an error (the `exp` timestamp has expired)

> **Note:** The `exp` and `sig` parameters are WSO2 APIM's way of protecting WSDL access for restricted APIs. Public APIs don't need signed URLs.

---

## Test Scenario 3: Tenant SOAP API

### 3.1 Create a tenant

1. Go to Carbon: `https://cp.eus2.apim.example.com/carbon` (admin / admin)
2. Navigate to **Configure** > **Multitenancy** > **Add New Tenant**
3. Fill in:
   - Domain: `test.com`
   - Admin username: `admin`
   - Admin password: `admin123`
4. Click **Register**

### 3.2 Create SOAP API as tenant

1. Open Publisher as tenant: `https://cp.eus2.apim.example.com/publisher`
2. Log in as `admin@test.com` / `admin123`
3. Create a SOAP API the same way as Scenario 1 (WSDL URL: `http://soap-calculator.apim.svc:8000/?wsdl`)
4. Deploy and Publish

### 3.3 Verify tenant WSDL access

1. Open DevPortal as tenant
2. Go to the Calculator API > **Overview**
3. Verify **Download WSDL** and **Copy WSDL URL** work
4. Copy the WSDL URL and open in browser — verify it returns WSDL XML
5. Optionally: restrict visibility and verify `exp`/`sig` parameters (same as Scenario 2)

---

## Test Scenario 4: SOAP Operations in DevPortal

### 4.1 Verify operations listing

1. Open DevPortal: `https://cp.eus2.apim.example.com/devportal`
2. Go to the **Calculator** API
3. Go to the **Documents** tab
4. Verify that SOAP operations are listed as a default document, showing:
   - `Add`
   - `Subtract`
   - `Multiply`
   - `Divide`

---

## Test with curl (optional)

If you want to test the SOAP API end-to-end through the gateway:

### Subscribe and get a token

1. In DevPortal, subscribe to the Calculator API (create an app if needed)
2. Generate production keys
3. Copy the access token

### Send a SOAP request

```bash
curl -sk -X POST https://gw.eus2.apim.example.com/calculator/1.0.0 \
  -H "Authorization: Bearer <TOKEN>" \
  -H "Content-Type: text/xml" \
  -H "SOAPAction: \"Add\"" \
  -d '<?xml version="1.0" encoding="UTF-8"?>
<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/"
                  xmlns:calc="http://calculator.example.com">
  <soapenv:Body>
    <calc:Add>
      <calc:a>10</calc:a>
      <calc:b>25</calc:b>
    </calc:Add>
  </soapenv:Body>
</soapenv:Envelope>'
```

Expected response — XML with `<calc:AddResult>35</calc:AddResult>`.

---

## Teardown

```bash
./samples/soap-calculator/undeploy-multi-dc.sh
```
