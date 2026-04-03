# Running Integration Tests on Azure VM with PostgreSQL

Run WSO2 APIM 4.7.0 integration tests in **standalone mode** from an Ubuntu VM on the eus2 vnet,
using Azure Database for PostgreSQL as the backend databases.

## Architecture

```
Azure VM (Ubuntu 22.04/24.04, eus2 vnet)
┌────────────────────────────────────────────┐
│  mvn test (standalone mode)                │
│                                            │
│  Test framework starts APIM locally        │   JDBC (port 5432, private endpoint)
│  APIM reads/writes via JDBC  ──────────────┼──────────────────────────────────────>
│                                            │   Azure DB for PostgreSQL
│  Tests exercise the local APIM             │   ├── shared_db  (test database)
│                                            │   └── apim_db    (test database)
└────────────────────────────────────────────┘
```

**How this differs from `integration-testing/`:**

| | `integration-testing/` | This guide |
|--|------------------------|------------|
| APIM server | Running on AKS (DC1) | Started locally by test framework |
| Test mode | Platform (`-DplatformTests`) | Standalone (default) |
| Database | H2 in-memory | Azure PostgreSQL (dedicated test DBs) |
| Port-forward required | Yes (HTTP 9763 + HTTPS 19443) | No |
| Source overrides required | Yes (13 files) | No |

> The overrides in `integration-testing/product-apim-overrides/` are **not needed** here.
> They solved AKS networking problems that don't exist in standalone mode.

---

## Prerequisites on the VM

### Step 1 — Install dependencies

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y openjdk-21-jdk maven git zip unzip curl postgresql-client
```

Verify:
```bash
java -version   # should show 21.x
mvn -version    # should show 3.8+
```

If `JAVA_HOME` is not picked up automatically by Maven:
```bash
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
echo 'export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64' >> ~/.bashrc
source ~/.bashrc
```

### Step 2 — Clone product-apim

```bash
git clone https://github.com/wso2/product-apim.git
cd product-apim
git checkout <branch-or-tag>   # e.g. main, or the 4.7.0 tag
```

---

## Step 3 — Build the Distribution Pack

The test framework unpacks and starts the APIM server from a zip. Build it from source:

```bash
cd product-apim/all-in-one-apim
export MAVEN_OPTS="-Xmx2g"
mvn clean install -Dmaven.test.skip=true
```

This takes ~15-20 minutes. The zip is produced at:

```
all-in-one-apim/modules/distribution/product/target/wso2am-4.7.0-SNAPSHOT.zip
```

> **Do not run `mvn clean install` on the distribution module again after Step 4** — it will overwrite the modified zip.

---

## Step 4 — Add the PostgreSQL JDBC Driver to the Pack

The APIM server starts from the zip, so the driver must be inside the zip before the tests unpack it.

```bash
cd product-apim/all-in-one-apim/modules/distribution/product/target/

# Download the PostgreSQL JDBC driver
curl -L -o postgresql-42.7.4.jar \
  https://jdbc.postgresql.org/download/postgresql-42.7.4.jar

# Unpack the zip, add the driver, repack
unzip wso2am-4.7.0-SNAPSHOT.zip
rm wso2am-4.7.0-SNAPSHOT.zip
cp postgresql-42.7.4.jar wso2am-4.7.0-SNAPSHOT/repository/components/lib/
zip -r wso2am-4.7.0-SNAPSHOT.zip wso2am-4.7.0-SNAPSHOT/
rm -rf wso2am-4.7.0-SNAPSHOT/
```

---

## Step 5 — Create Test Databases on Azure PostgreSQL

The VM is on the eus2 vnet and can reach the Azure Flexible Server private endpoint directly.
No firewall changes are needed.

### Verify connectivity

```bash
nslookup apim-4-7-eus2.postgres.database.azure.com
# Should resolve to a 10.x.x.x private IP
```

### Create the databases

```bash
psql "host=apim-4-7-eus2.postgres.database.azure.com port=5432 dbname=postgres \
      user=<admin-user> password=<password> sslmode=require"
```

Inside psql:
```sql
CREATE DATABASE shared_db;
CREATE DATABASE apim_db;
\q
```

### Run the WSO2 schema scripts

Extract the scripts from the modified pack:

```bash
cd product-apim/all-in-one-apim/modules/distribution/product/target/

unzip -o wso2am-4.7.0-SNAPSHOT.zip "wso2am-4.7.0/dbscripts/*" -d /tmp/apim-schema
```

Apply the scripts:

```bash
# shared_db schema (user management, registry, etc.)
psql "host=apim-4-7-eus2.postgres.database.azure.com port=5432 dbname=shared_db \
      user=<admin-user> password=<password> sslmode=require" \
  -f /tmp/apim-schema/wso2am-4.7.0/dbscripts/postgresql.sql

# apim_db schema (API manager tables)
psql "host=apim-4-7-eus2.postgres.database.azure.com port=5432 dbname=apim_db \
      user=<admin-user> password=<password> sslmode=require" \
  -f /tmp/apim-schema/wso2am-4.7.0/dbscripts/apimgt/postgresql.sql
```

---

## Step 6 — Configure pom.xml for PostgreSQL

Edit the tests-backend pom.xml:

```
product-apim/all-in-one-apim/modules/integration/tests-integration/tests-backend/pom.xml
```

Find the `<environmentVariables>` block inside the surefire plugin configuration. It currently
contains H2 entries — replace them with:

```xml
<environmentVariables>
    <SHARED_DATABASE_DRIVER>org.postgresql.Driver</SHARED_DATABASE_DRIVER>
    <SHARED_DATABASE_URL>jdbc:postgresql://apim-4-7-eus2.postgres.database.azure.com:5432/shared_db?sslmode=require</SHARED_DATABASE_URL>
    <SHARED_DATABASE_USERNAME>your-admin-user</SHARED_DATABASE_USERNAME>
    <SHARED_DATABASE_PASSWORD>your-password</SHARED_DATABASE_PASSWORD>
    <SHARED_DATABASE_VALIDATION_QUERY>SELECT 1</SHARED_DATABASE_VALIDATION_QUERY>
    <API_MANAGER_DATABASE_DRIVER>org.postgresql.Driver</API_MANAGER_DATABASE_DRIVER>
    <API_MANAGER_DATABASE_URL>jdbc:postgresql://apim-4-7-eus2.postgres.database.azure.com:5432/apim_db?sslmode=require</API_MANAGER_DATABASE_URL>
    <API_MANAGER_DATABASE_USERNAME>your-admin-user</API_MANAGER_DATABASE_USERNAME>
    <API_MANAGER_DATABASE_PASSWORD>your-password</API_MANAGER_DATABASE_PASSWORD>
    <API_MANAGER_DATABASE_VALIDATION_QUERY>SELECT 1</API_MANAGER_DATABASE_VALIDATION_QUERY>
</environmentVariables>
```

> **Azure PostgreSQL Flexible Server:** use the plain username (e.g. `adminuser`), not `adminuser@servername`.

---

## Step 7 — Run Integration Tests

From the `all-in-one-apim` directory, run a test group in standalone mode.
Omitting `-DplatformTests` tells the framework to start its own local APIM server.

```bash
cd product-apim/all-in-one-apim

PRODUCT_APIM_TESTS="apim-integration-tests-api-common" \
mvn clean install \
  -pl modules/integration/tests-integration/tests-backend \
  2>&1 | tee ~/test-results.log
```

> Do **not** add `-am` — it would rebuild the distribution module and overwrite the modified zip from Step 4.

The `carbon.zip` property in pom.xml already points to the correct path:
```
${basedir}/../../../distribution/product/target/wso2am-4.7.0-SNAPSHOT.zip
```

### Run all tests

To run every test group without filtering by `PRODUCT_APIM_TESTS`:

```bash
cd product-apim/all-in-one-apim

mvn clean install \
  -pl modules/integration/tests-integration/tests-backend \
  2>&1 | tee ~/test-results-all.log
```

### Other test groups

| Group | PRODUCT_APIM_TESTS value |
|-------|--------------------------|
| API common | `apim-integration-tests-api-common` |
| API product | `apim-integration-tests-api-product` |
| API lifecycle | `apim-integration-tests-api-lifecycle` |
| API governance | `apim-integration-tests-api-governance` |

---

## Re-running Tests (Clean State)

PostgreSQL databases accumulate state between test runs. For a clean run, recreate them:

```bash
PGCONN="host=apim-4-7-eus2.postgres.database.azure.com port=5432 user=<admin-user> password=<password> sslmode=require"

# Drop and recreate
psql "$PGCONN dbname=postgres" -c "DROP DATABASE IF EXISTS apim_db;"
psql "$PGCONN dbname=postgres" -c "DROP DATABASE IF EXISTS shared_db;"
psql "$PGCONN dbname=postgres" -c "CREATE DATABASE shared_db;"
psql "$PGCONN dbname=postgres" -c "CREATE DATABASE apim_db;"

# Re-apply schemas
psql "$PGCONN dbname=shared_db" -f /tmp/apim-schema/wso2am-4.7.0/dbscripts/postgresql.sql
psql "$PGCONN dbname=apim_db"   -f /tmp/apim-schema/wso2am-4.7.0/dbscripts/apimgt/postgresql.sql
```

---

## Troubleshooting

**`org.postgresql.Driver not found` during startup**
The driver is missing from the pack. Redo Step 4. Confirm it's at
`wso2am-4.7.0/repository/components/lib/postgresql-42.7.4.jar` inside the zip.

**`Connection refused` or hostname not resolving**
```bash
nslookup apim-4-7-eus2.postgres.database.azure.com
```
Should return a `10.x.x.x` address. If it returns a public IP, the private endpoint DNS zone
is not linked to the eus2 vnet — contact the infra team.

**SSL/TLS errors**
Ensure `sslmode=require` is present in both JDBC URLs. Azure PostgreSQL enforces TLS by default.

**Schema errors on APIM startup**
Tables already exist from a previous run. Drop and recreate the databases (see above).

**APIM fails to start (no DB error)**
Check the APIM log in the temporary unpack directory:
```bash
find /tmp -name "wso2carbon.log" 2>/dev/null | head -5
# or check surefire reports
cat modules/integration/tests-integration/tests-backend/target/surefire-reports/*.txt | grep -A5 "ERROR"
```

**Build runs out of memory**
```bash
export MAVEN_OPTS="-Xmx2g"
```

**Modified zip gets overwritten**
If you accidentally ran `mvn clean install` on the full project, redo Step 4 to re-add the driver.
