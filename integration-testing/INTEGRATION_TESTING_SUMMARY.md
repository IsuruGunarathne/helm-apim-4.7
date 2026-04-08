# Integration Testing Summary

Technical summary of work done to run WSO2 APIM 4.7 product-apim integration tests against a distributed AKS deployment. Use this to onboard a new session.

## Goal

Run `product-apim/all-in-one-apim/modules/integration/tests-integration/tests-backend` integration tests against APIM 4.7 deployed on AKS across two data centers (DC1: `aks-apim-eus1`, DC2: `aks-apim-wus2`). The test framework was designed for a local all-in-one server — we adapted it for a remote distributed deployment.

## Three Core Problems Solved

### 1. AuthenticationAdmin Remote Address Validation

**Problem:** Carbon's `AuthenticationAdmin.login(user, pass, remoteAddress)` validates that the passed hostname resolves to the HTTP request source IP. Through the nginx ingress, the source IP is the nginx pod — it doesn't match the hostname's DNS.

**Solution:** `kubectl port-forward` on HTTP port 9763. When connecting to `localhost`, the source IP is `127.0.0.1` which matches `localhost` resolution. All our modified REST API code uses HTTP via `getWebAppURL()`.

### 2. TLS Certificate Mismatch (EC vs RSA)

**Problem:** The CP pod has both RSA and EC TLS certificates. Java prefers ECDHE-ECDSA cipher suites, so it always gets the EC cert (CN=dynamic, O=dynamic, issued by `dynamiclistener-ca`). This cert isn't in any standard truststore. Meanwhile, `openssl` defaults to RSA ciphers and gets the `wso2carbon` cert — causing confusion during debugging.

Additionally, `ArchiveExtractorUtil` (carbon-automation JAR) overrides `javax.net.ssl.trustStore` at runtime to point to `wso2carbon.jks`, ignoring any JVM argument we set.

**Solution:** Extracted the EC cert using a custom Java program (connects with trust-all TrustManager), then imported it directly into `wso2carbon.jks` (the keystore that `ArchiveExtractorUtil` enforces). Port-forwarded HTTPS on port 19443->9443 for the carbon library's `LoginLogoutClient` which hardcodes HTTPS via `getBackEndUrl()`.

Port 19443 (not 9443) because Rancher Desktop's `steve` process occupies IPv4:9443.

### 3. Hardcoded `localhost:9943` URLs

**Problem:** Five REST API client classes had `https://localhost:9943` hardcoded (9943 = 9443 + 500 port offset used in local testing). In our setup, nothing listens on 9943.

**Solution:** Added configurable `baseUrl` constructors to `RestAPIGatewayImpl`, `RestAPIServiceCatalogImpl`, `RestAPIInternalImpl`. Updated callers (`RestAPIPublisherImpl`, `RestAPIStoreImpl`, `APIMIntegrationBaseTest`) to pass the actual URL from automation.xml configuration. Old no-arg constructors preserved for backward compatibility.

### Additional Fix: Auto-DCR in ClientAuthenticator

**Problem:** `APIManagerConfigurationChangeTest` normally runs first and calls `makeDCRRequest()` to populate a static `applicationKeyMap`. This test fails in platform mode (no `deployment.toml`), so all subsequent `getAccessToken()` calls fail with null `applicationKeyBean`.

**Solution:** Modified `ClientAuthenticator.getAccessToken()` to check if `applicationKeyBean` is null and auto-call `makeDCRRequest()`. Also changed `HttpsURLConnection` cast to `HttpURLConnection` with conditional SSL setup (handles both HTTP and HTTPS token endpoints).

## All Modified Files

Files are preserved in `integration-testing/product-apim-overrides/`, mirroring the `product-apim/all-in-one-apim/` directory structure.

### Java — tests-common/integration-test-utils

| File | What Changed |
|------|-------------|
| `ClientAuthenticator.java` | Null-check `applicationKeyBean` with auto-DCR; `HttpURLConnection` with conditional SSL |
| `RestAPIInternalImpl.java` | New `(user, pass, tenant, baseUrl)` constructor; old 3-arg delegates with default |
| `RestAPIGatewayImpl.java` | New `(user, pass, tenant, baseUrl)` constructor; old 3-arg delegates with default |
| `RestAPIPublisherImpl.java` | Line 259: passes `publisherURL` to `RestAPIGatewayImpl` 4-arg constructor |
| `RestAPIServiceCatalogImpl.java` | New `(user, pass, tenant, baseUrl)` constructor; old 3-arg delegates with default |
| `RestAPIStoreImpl.java` | Lines 170, 187: passes `storeURL` to `RestAPIGatewayImpl` 4-arg constructor |
| `APIMIntegrationBaseTest.java` | Added `getHttpBackendUrl(ctx)` helper returning `ctx.getWebAppURL() + "/services/"`. Replaced all 12 `getBackEndUrl()` calls. Passes `publisherURLHttps` to ServiceCatalog, `keyMangerUrl` to Internal |
| `LoginLogoutClient.java` | Uses `getWebAppURL() + "/services/"` instead of `getBackEndUrl()` for HTTP |
| `APIMURLBean.java` | `webAppURLHttps` built from `getWebAppURL()` (HTTP) instead of `getBackEndUrl()` (HTTPS) |

### Config — tests-backend

| File | What Changed |
|------|-------------|
| `pom.xml` | Platform profile surefire: added `-Djavax.net.ssl.trustStore=/tmp/test-truststore.jks`, `<disableVerification>true</disableVerification>` |
| `automation.xml` | CP instances: `http=9763`, `https=19443`. Removed `userStoreUser` (referenced non-existent `secondary` user store domain). `executionEnvironment=platform` |
| `wso2carbon.jks` | Imported `dynamiclistener-ca` EC cert with alias `dynamiclistener-ec` (PKCS12 format, password: `wso2carbon`, 152 entries) |
| `platform-test-host-config.xsl` | Separate XSL templates per port type: `xs:port[@type='http']` -> 9763, `xs:port[@type='https']` -> 19443 for CP instances |

## Key Technical Details

### automation.xml Instance Names
The instance names in automation.xml are `store-old`, `publisher-old`, `keyManager`, `gateway-mgt`, `gateway-wrk`, `backend-server`. Note `store-old` and `publisher-old` (not `store`/`publisher`).

### URL Flow
- `getWebAppURL()` returns `http://host:httpPort` (our REST API path)
- `getBackEndUrl()` returns `https://host:httpsPort/services/` (carbon library's SOAP path)
- `APIMURLBean.webAppURLHttps` is misleadingly named — now contains HTTP URL. Used by 100+ test classes.

### disableVerification System Property
`RestAPIStoreImpl` and `RestAPIPublisherImpl` check `System.getProperty("disableVerification")`. When `true`, skip `waitUntilApplicationAvailableInGateway()` and `waitUntilAPIDeployedInGateway()` calls which use the gateway REST API (not accessible in distributed setup).

### EC Cert Extraction
If the `dynamiclistener-ca` cert rotates, extract it with this Java program:
```java
// SaveCert.java — connect with trust-all, save server cert to PEM
import javax.net.ssl.*;
import java.security.cert.*;
import java.io.*;
import java.util.Base64;

public class SaveCert {
    public static void main(String[] args) throws Exception {
        String host = args[0];
        int port = Integer.parseInt(args[1]);
        String outFile = args[2];
        TrustManager tm = new X509TrustManager() {
            public void checkClientTrusted(X509Certificate[] c, String a) {}
            public void checkServerTrusted(X509Certificate[] c, String a) {}
            public X509Certificate[] getAcceptedIssuers() { return null; }
        };
        SSLContext ctx = SSLContext.getInstance("TLS");
        ctx.init(null, new TrustManager[]{tm}, null);
        SSLSocket s = (SSLSocket) ctx.getSocketFactory().createSocket(host, port);
        s.startHandshake();
        Certificate cert = s.getSession().getPeerCertificates()[0];
        s.close();
        try (PrintWriter w = new PrintWriter(outFile)) {
            w.println("-----BEGIN CERTIFICATE-----");
            w.println(Base64.getMimeEncoder(64, "\n".getBytes()).encodeToString(cert.getEncoded()));
            w.println("-----END CERTIFICATE-----");
        }
        System.out.println("Saved cert to " + outFile);
    }
}
```

## Current Test Results (apim-integration-tests-api-common)

```
Tests run: 91, Failures: 9, Errors: 0, Skipped: 81
```

- **81 skipped**: `APIManagerConfigurationChangeTestSuite` fails (expected — no local deployment.toml), causing server-mgt suite tests to skip
- **3 unique root failures**: 1 expected (deployment.toml), 2 need investigation (null applicationResponse from `createApplication`)
- **6 cascading cleanup failures**: Tests that failed during setup also fail during destroy/cleanup

## What Remains To Be Done

1. **Investigate `createApplication` returning null** — `RestAPIStoreImpl.createApplication()` catches `ApiException` and returns null when `getResponseBody()` doesn't contain "already exists". Need to add logging or fix null-safety in the catch block to understand the actual API error.

2. **Investigate `AddEditRemoveRESTResourceTestCase`** — Fails during `createAPIRevision` with null response body. Same null-safety issue in the publisher client.

3. **Test more test groups** — Only `apim-integration-tests-api-common` has been tested. Other groups (`api-product`, `api-governance`, `api-lifecycle`) need to be run.

4. **DC2 testing** — Currently only tested against DC1 (`aks-apim-eus1`). Need to update XSL/automation.xml hostnames for DC2 (`aks-apim-wus2`) and verify.

5. **Port-forward auto-reconnect** — `kubectl port-forward` drops during long runs. Consider a wrapper script or tool like `kubefwd`.

## How to Run

```bash
cd integration-testing

# 1. Deploy test backends (one-time)
./deploy-backends.sh

# 2. Apply overrides to product-apim
./apply-overrides.sh

# 3. Start port-forwards
kubectl port-forward svc/wso2am-cp-service 9763:9763 -n apim --context aks-apim-eus1 &
kubectl port-forward svc/wso2am-cp-service 19443:9443 -n apim --context aks-apim-eus1 &

# 4. Run tests
cd ../product-apim/all-in-one-apim
PRODUCT_APIM_TESTS="apim-integration-tests-api-common" \
mvn clean install -DplatformTests -Pwithout-restart \
  -pl modules/integration/tests-integration/tests-backend
```
