# Running Integration Tests Against AKS

This guide explains how to run the product-apim integration tests against the distributed APIM 4.7 deployment on Azure Kubernetes Service.

## Architecture

```
Your Mac (test runner)                         AKS Cluster (DC1: aks-apim-eus1)
┌──────────────────────────┐         ┌──────────────────────────────────┐
│  mvn test                │         │                                  │
│                          │         │  CP pod (wso2am-cp-service)      │
│  REST API clients ───────┼─9763──> │    port-forward HTTP  -> :9763   │
│  (Publisher/Store/Admin) │         │                                  │
│                          │         │  CP pod (SOAP/login)             │
│  SOAP admin clients ─────┼─19443─> │    port-forward HTTPS -> :9443   │
│  (LoginLogoutClient,     │         │                                  │
│   UserManagement, etc.)  │         │  Gateway (ingress)               │
│                          │         │    gw.eus1.apim.example.com:443  │
│  Gateway API calls ──────┼──443──> │                                  │
│                          │         │  test-backends.apim.svc:8080     │
│                          │         │    (17 WAR files in Tomcat)      │
└──────────────────────────┘         └──────────────────────────────────┘
```

**Two port-forwards are needed:**
- **9763 (HTTP)** — REST API calls (Publisher, DevPortal, Admin, KeyManager, OAuth token endpoints). Our modified code routes these through `getWebAppURL()` which returns HTTP URLs.
- **19443 -> 9443 (HTTPS)** — SOAP admin calls (login, user management, tenant management). The carbon-automation library's `LoginLogoutClient` hardcodes `getBackEndUrl()` which always returns HTTPS. We can't modify that JAR, so we port-forward HTTPS too.

Port 19443 (not 9443) is used because Rancher Desktop's `steve` process occupies IPv4:9443, causing kubectl port-forward to bind IPv6 only, which Java can't connect to.

## Prerequisites

- Docker Desktop with buildx (for building the test-backends image)
- Maven 3.8+, JDK 17 or 21
- `kubectl` configured with AKS contexts (`aks-apim-eus1`, `aks-apim-wus2`)
- APIM deployed on both DCs

## Step 1 — Build and Deploy Test Backend Services

The integration tests need backend web apps (JAX-RS services) running inside the cluster. We package all 17 WAR files into a Tomcat container.

### Build the image

```bash
cd integration-testing
./build-backends.sh
```

This copies WAR files from `product-apim/.../artifacts/AM/war/` and builds/pushes a multi-platform image (`isurugunarathne/apim-test-backends:latest`). Only needed once, or when WAR files change.

### Deploy to both DCs

```bash
./deploy-backends.sh
```

Deploys the `test-backends` service (port 8080) to both DCs.

### Verify

```bash
kubectl -n apim exec deploy/wso2am-gw-deployment -- \
  curl -s http://test-backends.apim.svc:8080/jaxrs_basic/services/customers/customerservice/customers/123
```

You should get a customer XML response.

## Step 2 — Apply Test Framework Overrides

The product-apim test framework assumes a local all-in-one server. We've modified 13 files to make it work against a distributed AKS deployment. These overrides are stored in `product-apim-overrides/`.

### Apply with script (recommended)

```bash
cd integration-testing
./apply-overrides.sh
```

This copies all override files into `product-apim/all-in-one-apim/` and rebuilds the `tests-common` module.

### What the overrides change

| File | Change |
|------|--------|
| `ClientAuthenticator.java` | Auto-DCR when token map is empty; handles both HTTP and HTTPS URLs |
| `RestAPIInternalImpl.java` | Configurable base URL (was hardcoded `localhost:9943`) |
| `RestAPIGatewayImpl.java` | Configurable base URL (was hardcoded `localhost:9943`) |
| `RestAPIPublisherImpl.java` | Passes publisher URL to gateway client |
| `RestAPIServiceCatalogImpl.java` | Configurable base URL (was hardcoded `localhost:9943`) |
| `RestAPIStoreImpl.java` | Passes store URL to gateway client |
| `APIMIntegrationBaseTest.java` | `getHttpBackendUrl()` helper; passes URLs to all REST API impls |
| `LoginLogoutClient.java` | Uses `getWebAppURL()` (HTTP) instead of `getBackEndUrl()` (HTTPS) |
| `APIMURLBean.java` | `webAppURLHttps` built from `getWebAppURL()` (HTTP) |
| `pom.xml` | Platform profile: truststore JVM args, `disableVerification=true` |
| `automation.xml` | CP ports: http=9763, https=19443; removed invalid userStoreUser |
| `wso2carbon.jks` | Imported `dynamiclistener-ca` EC cert for HTTPS port-forward |
| `platform-test-host-config.xsl` | Port-type-specific XSL templates for dual port-forward |

## Step 3 — Start Port-Forwards

Open **two** terminals (or use `&` to background):

```bash
# Terminal 1: HTTP (REST APIs, OAuth tokens)
kubectl port-forward svc/wso2am-cp-service 9763:9763 -n apim --context aks-apim-eus1

# Terminal 2: HTTPS (SOAP admin services — LoginLogoutClient, UserPopulator)
kubectl port-forward svc/wso2am-cp-service 19443:9443 -n apim --context aks-apim-eus1
```

Or as background processes:

```bash
kubectl port-forward svc/wso2am-cp-service 9763:9763 -n apim --context aks-apim-eus1 &
kubectl port-forward svc/wso2am-cp-service 19443:9443 -n apim --context aks-apim-eus1 &
```

### Verify both work

```bash
# HTTP
curl -s http://localhost:9763/services/AuthenticationAdmin?wsdl | head -1

# HTTPS
curl -sk https://localhost:19443/services/AuthenticationAdmin?wsdl | head -1
```

Both should return XML starting with `<wsdl:definitions`.

## Step 4 — Run Integration Tests

### Configuration

The `platform-test-host-config.xsl` transforms `automation.xml` with:

| Instance | Hostname | HTTP Port | HTTPS Port | Connection |
|----------|----------|-----------|------------|------------|
| store-old (DevPortal) | `localhost` | 9763 | 19443 | port-forward |
| publisher-old | `localhost` | 9763 | 19443 | port-forward |
| keyManager | `localhost` | 9763 | 19443 | port-forward |
| gateway-mgt | `localhost` | 9763 | 19443 | port-forward |
| gateway-wrk | `gw.eus1.apim.example.com` | 443 | 443 | ingress (HTTPS) |
| backend-server | `test-backends.apim.svc` | 8080 | 8080 | cluster-internal |

If your gateway hostname differs, edit `platform-test-host-config.xsl` in the overrides and re-apply.

### Run a specific test group

```bash
cd product-apim/all-in-one-apim

PRODUCT_APIM_TESTS="apim-integration-tests-api-common" \
mvn clean install -DplatformTests -Pwithout-restart \
  -pl modules/integration/tests-integration/tests-backend
```

### Run all tests (excluding restart/config tests)

```bash
cd product-apim/all-in-one-apim

mvn clean install -DplatformTests -Pwithout-restart \
  -pl modules/integration/tests-integration/tests-backend
```

### Run specific test classes

```bash
PRODUCT_APIM_TEST_CLASSES="APICreationTestCase,APIRevisionTestCase" \
mvn clean install -DplatformTests -Pwithout-restart \
  -pl modules/integration/tests-integration/tests-backend
```

## Test Groups

### Start with these (CRUD-heavy, no gateway invocation needed)

| Test name in testng.xml | What it tests |
|------------------------|---------------|
| `apim-integration-tests-api-common` | API creation, revisions, OAS, MCP server |
| `apim-integration-tests-api-product` | API product creation and lifecycle |
| `apim-integration-tests-api-governance` | Rulesets, policies, compliance |

### Then expand to these (require working backend services)

| Test name in testng.xml | What it tests |
|------------------------|---------------|
| `apim-integration-tests-api-lifecycle` | API lifecycle, invocation, endpoint certs |
| `apim-integration-tests-api-lifecycle-2` | Throttling, tokens, headers, operation policies |
| `apim-email-secondary-userstore-tests` | Visibility, CORS, scopes, tokens |
| `apim-integration-tests-samples` | URI templates, default versions, PATCH |

## Current Test Results

With `apim-integration-tests-api-common`:

```
Tests run: 91, Failures: 9, Errors: 0, Skipped: 81
```

### Failure Breakdown

| # | Failure | Root Cause | Fixable? |
|---|---------|-----------|----------|
| 1 | `APIManagerConfigurationChangeTestSuite` | Needs local `deployment.toml` — doesn't exist in platform mode | No (expected) |
| 2 | `AdvancedWebAppDeploymentConfig` | `createApplication` returns null — likely app already exists from previous run | Investigate |
| 3 | `APISecurityAuditTestCase.destroy` | Cleanup failure cascading from setup | No (cascading) |
| 4 | `AddEditRemoveRESTResourceTestCase` | `ApiException` with null response body during revision creation | Investigate |
| 5 | `JWTRevocationTestCase.setEnvironment` | `createApplication` returns null | Same as #2 |
| 6 | `JWTRevocationTestCase.destroy` | Cleanup failure cascading from #5 | No (cascading) |
| 7-8 | `APICreationTestCase.cleanUpArtifacts` | `apiId` is null because creation failed earlier | No (cascading) |
| 9 | `AdvancedWebAppDeploymentConfig.cleanUpArtifacts` | Cascading from #2 | No (cascading) |

**Unique root failures: 3** (#1 expected, #2 and #4 need investigation)
**Cascading cleanup failures: 6**

The 81 skipped tests are skipped because `APIManagerConfigurationChangeTestSuite` (which runs first in `testng-server-mgt.xml`) fails, causing the server management test suite to skip all dependent tests. The actual test classes from `testng.xml` do run.

## Test Results Location

```
product-apim/all-in-one-apim/modules/integration/tests-integration/tests-backend/target/surefire-reports/
```

Quick summary:
```bash
cat product-apim/all-in-one-apim/modules/integration/tests-integration/tests-backend/target/surefire-reports/TestSuite.txt
```

## Known Limitations

1. **`APIManagerConfigurationChangeTestSuite` always fails in platform mode** — This test modifies `deployment.toml` on a local server. No local server exists in platform mode. This is expected and causes 81 tests in the server-mgt suite to be skipped.

2. **Gateway management API not accessible** — The gateway REST API (`/api/am/gateway/v2`) runs on the gateway pod's management port (9443), which isn't exposed through ingress. Tests that call `RestAPIGatewayImpl` methods (like `waitUntilApplicationAvailableInGateway`) are handled by `disableVerification=true`.

3. **Port-forward stability** — `kubectl port-forward` can die silently during long test runs. If tests suddenly fail with "Connection refused", restart the port-forwards. Consider using a wrapper that auto-reconnects.

4. **Rancher Desktop port conflict** — Rancher Desktop's `steve` process binds IPv4:9443. That's why we use 19443 instead. If you don't have Rancher, you could use 9443 directly (update automation.xml and XSL).

5. **TLS cert mismatch** — The CP pod serves different TLS certs depending on cipher suite preference (EC cert for ECDHE-ECDSA, RSA cert for RSA ciphers). Java always gets the EC cert (`dynamiclistener-ca`). The override `wso2carbon.jks` has this cert pre-imported. If the cert rotates, re-extract and import it:
   ```bash
   # Extract EC cert from server
   javac /tmp/SaveCert.java  # see INTEGRATION_TESTING_SUMMARY.md for source
   java -cp /tmp SaveCert localhost 19443 /tmp/dynamiclistener-ec.pem

   # Import into wso2carbon.jks
   keytool -importcert -alias dynamiclistener-ec \
     -file /tmp/dynamiclistener-ec.pem \
     -keystore product-apim-overrides/.../wso2carbon.jks \
     -storepass wso2carbon -noprompt
   ```

6. **`createApplication` returning null** — Some tests fail because `RestAPIStoreImpl.createApplication()` catches `ApiException` and returns null instead of propagating the error. This is a product-apim framework bug, not specific to our setup.

## Cleanup

```bash
cd integration-testing
./undeploy-backends.sh
```
