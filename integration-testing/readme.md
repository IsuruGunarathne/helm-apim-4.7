# Running Integration Tests Against AKS

This guide explains how to run the product-apim integration tests against the distributed APIM 4.7 deployment on Azure Kubernetes Service.

## Architecture

```
Your Mac (test runner)                    AKS Cluster
┌─────────────────────┐         ┌──────────────────────────────┐
│  mvn test           │         │                              │
│  (Publisher client)─┼──443──> │  CP ingress -> control-plane │
│  (Store client)─────┼──443──> │                              │
│  (Gateway client)───┼──443──> │  GW ingress -> gateway       │
│                     │         │                              │
│                     │         │  gateway ──8080──> test-backends (Tomcat)
│                     │         │            (17 WAR files)     │
└─────────────────────┘         └──────────────────────────────┘
```

The test framework runs on your Mac, connects to APIM via ingress (HTTPS/443). When tests create APIs, they set the backend endpoint to `http://test-backends.apim.svc:8080/...` — the gateway resolves this cluster-internally.

## Prerequisites

- Docker Desktop with buildx (for building the test-backends image)
- Maven 3.8+, JDK 17
- `kubectl` configured with AKS contexts (`aks-apim-eus2`, `aks-apim-wus2`)
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

## Step 2 — Build Test Dependencies

The test modules depend on `tests-common` (REST API clients, utils, framework extensions) which are `4.7.0-SNAPSHOT` artifacts not in public Maven repos. Build them first:

```bash
cd product-apim/all-in-one-apim

# Build tests-common modules (skip running tests)
mvn clean install -pl modules/integration/tests-common -DskipTests -am
```

If the build fails looking for `carbon.zip` (the APIM distribution), you also need:

```bash
mvn clean install -pl modules/distribution/product -DskipTests -am
```

## Step 3 — Run Integration Tests

### Configuration

The `platform-test-host-config.xsl` has already been updated with:

| Instance | Hostname | Port |
|----------|----------|------|
| store-old (DevPortal) | `cp.eus2.apim.example.com` | 443 |
| publisher-old | `cp.eus2.apim.example.com` | 443 |
| keyManager | `cp.eus2.apim.example.com` | 443 |
| gateway-mgt | `cp.eus2.apim.example.com` | 443 |
| gateway-wrk | `gw.eus2.apim.example.com` | 443 |
| backend-server | `test-backends.apim.svc` | 8080 |

If your hostnames differ, edit:
`product-apim/all-in-one-apim/modules/integration/tests-integration/tests-backend/src/test/resources/platform-test-host-config.xsl`

### Run all tests (excluding restart/config tests)

```bash
cd product-apim/all-in-one-apim

mvn clean install -DplatformTests -Pwithout-restart \
  -pl modules/integration/tests-integration/tests-backend
```

### Run a specific test group

Use the `PRODUCT_APIM_TESTS` environment variable (comma-separated test names from testng.xml):

```bash
PRODUCT_APIM_TESTS="apim-integration-tests-api-common" \
mvn clean install -DplatformTests -Pwithout-restart \
  -pl modules/integration/tests-integration/tests-backend
```

### Run specific test classes

```bash
PRODUCT_APIM_TEST_CLASSES="APICreationTestCase,APIRevisionTestCase" \
mvn clean install -DplatformTests -Pwithout-restart \
  -pl modules/integration/tests-integration/tests-backend
```

## Recommended Test Groups

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

## Test Results

Results are in:
```
product-apim/all-in-one-apim/modules/integration/tests-integration/tests-backend/target/surefire-reports/
```

Quick summary:
```bash
grep -c "PASSED\|FAILED\|SKIPPED" product-apim/all-in-one-apim/modules/integration/tests-integration/tests-backend/target/surefire-reports/testng-results.xml
```

## Known Limitations

1. **HTTP-only tests may fail** — The ingress only exposes HTTPS (443). Tests that use `getWebAppURLHttp()` construct URLs like `http://host:443/` which won't work. Most tests use HTTPS.

2. **Server management tests skipped** — Tests annotated `@SetEnvironment(STANDALONE)` (server startup checks, OSGi bundle checks) are automatically skipped in platform mode.

3. **Restart tests not applicable** — Tests that restart the server or change `deployment.toml` can't work against a live K8s deployment. Use `-Pwithout-restart` to skip them.

4. **Tenant tests may need setup** — Some tests create tenants. Ensure the APIM admin credentials (admin/admin) work against your deployment.

5. **TLS trust** — If you get SSL errors, import your ingress certificate into the JVM truststore:
   ```bash
   # Export the cert
   openssl s_client -connect cp.eus2.apim.example.com:443 -servername cp.eus2.apim.example.com \
     </dev/null 2>/dev/null | openssl x509 > /tmp/apim-cert.pem

   # Import into JVM truststore
   sudo keytool -importcert -alias apim-aks -file /tmp/apim-cert.pem \
     -keystore $JAVA_HOME/lib/security/cacerts -storepass changeit -noprompt
   ```

   Or pass `-Djavax.net.ssl.trustStore=/path/to/your-truststore.jks` to Maven.

## Cleanup

```bash
cd integration-testing
./undeploy-backends.sh
```
