# M3 PostgreSQL Canary Application (Disposable Test Fixture)

This is a **test-only** single-container application for v1.14.0 M3-B/C staging. It does not modify the reusable Terraform modules or qualify a business production application. M2's original `minimal-http-app` stays intact.

The app uses PostgreSQL to write immutable SHA-256 canary rows and read them across a controlled RDS failover or an isolated backup restore.

## HTTP contract

| Route | Auth | Behavior |
|---|---|---|
| `GET /health` | None | 200 while the process is alive, independently of RDS. Use for ECS/ALB liveness so a deliberate database failover does not trigger a task-replacement storm. |
| `GET /ready` | None | 200 if a fresh, TLS-verified PostgreSQL connection executes `SELECT 1`; 503 on DB failure. Does not establish that the canary table exists. |
| `PUT /canary/<id>` | Bearer token | JSON body `{"value":"<synthetic string>"}`; insert immutable SHA-256 digest into `public.m3_canary`. New=201, identical retry=200, conflicting value=409, DB error=503. |
| `GET /canary/<id>` | Bearer token | Return stored digest only; 404 if missing, 503 on DB error. |

IDs use 1–64 letters/digits/periods/underscores/hyphens. Payload values are 1–1024 UTF-8 bytes; request bodies are limited to 2048 bytes. Plaintext payloads are never stored. Queries are parameterized, errors omit secrets, and a new short-lived connection is opened per request to make failover recovery measurable.

The connection uses `sslmode=verify-full` and the AWS `us-east-1` RDS CA bundle fetched into the container image **at build time**. Review the downloaded certificate chain and build before publishing; the existing release path then pins the ECR image by immutable digest. Do not disable certificate verification or use a raw DB IP address.

## M3-B deployment sequence

1. **Initial bootstrap:** The maintainer is resetting the canonical `test` service's `image_digest` to `null` independently. **This PR intentionally leaves `environments/staging/container-workloads.auto.tfvars.json` untouched.** With the service still registered and `repository_name="test"`, a protected production-profile staging Apply provisions its ECR repo and RDS but does not create ECS/ALB for the null digest.
2. **Confirm effective topology:** Before the initial Apply, review the saved Plan for the staging account in `us-east-1` with `deployment_profile=production`, three AZs, Network Firewall, Multi-AZ RDS, AWS Backup, logging and deletion protection. Set `production_retirement_mode=false` for normal deployment. After a successful initial Apply, use Terraform outputs for the **new** RDS DNS hostname, DB name and master secret ARN; do not reuse the destroyed M2 endpoint.
3. **Bootstrap least-privilege DB credentials:** From an authorized *private* connection to PostgreSQL (such as a controlled SSM session to a VPC host), use an administrator to run `CREATE ROLE m3_canary_app LOGIN;` and set its password interactively with `psql`'s `\password m3_canary_app`. As a database owner, execute [`sql/schema.sql`](sql/schema.sql), which creates `public.m3_canary` and grants only schema usage, table SELECT and table INSERT to that login. Do not store SQL passwords, RDS master credentials, or credential-bearing DSNs in Git.
4. **Create startup configuration:** Use AWS Secrets Manager to create two independent **raw-string** values: `M3_DB_PASSWORD` (application role password) and `M3_CANARY_TOKEN` (a new, random bearer token of at least 32 characters). Put the RDS DNS hostname in a **separate SSM Parameter Store String parameter** for `M3_DB_HOST`. Record the full ARNs of all three references, but do **not** commit the actual RDS hostname or credentials to Git. If using customer-managed KMS keys, include only the required key ARNs in `task_execution_kms_key_arns` and verify execution-role/key-policy permissions. AWS-managed `aws/secretsmanager` encryption does not use the same explicit decrypt grant.
5. **Configure service:** In a separate reviewed change (not this PR), preserve the canonical `test` service's ingress and port 8080 and configure `database_access=true`, `desired_count=3`, `scaling=null`, a container health command hitting `/health`, and these *partial* input examples:

   ```json
   {
     "environment_variables": {
       "M3_DB_PORT": "5432",
       "M3_DB_NAME": "appdb",
       "M3_DB_USER": "m3_canary_app"
     },
     "ssm_parameters": {
       "M3_DB_HOST": "<full ARN of SSM String parameter containing RDS DNS hostname>"
     },
     "secrets_manager_secrets": {
       "M3_DB_PASSWORD": "<full ARN of raw-string password secret>",
       "M3_CANARY_TOKEN": "<full ARN of raw-string bearer-token secret>"
     },
     "task_execution_kms_key_arns": ["<CMK ARN, only if required>"],
     "health_check": {
       "command": ["CMD-SHELL", "python -c \"from urllib.request import urlopen; assert urlopen('http://127.0.0.1:8080/health',timeout=2).status == 200\""],
       "interval": 30,
       "timeout": 5,
       "retries": 3,
       "start_period": 30
     }
   }
   ```

   These are **placeholders**, not deployable full service config. Retain existing CPU/memory, ingress and deployment limits unless review warrants changing them. Set `task_execution_kms_key_arns=[]` only if no customer-managed KMS decrypt grant is necessary. Keep the digest `null` until the image is published.
6. **Publish and promote:** After ECR exists, dispatch **Deploy Application** from an authorized publishing branch with `environment=staging`, `service=test`, `build_context=tests/fixtures/deployment/postgres-canary-app` and `dockerfile=Dockerfile`. It builds/pushes the image and opens a digest-only release PR; it does **not** apply Terraform. Review/merge that PR, then run the protected **Terraform Apply** workflow, verifying the saved Plan, image digest, ECS convergence and ALB health.
7. **Qualify before M3-C:** Run the 16 existing baseline validators and actual HTTPS/SQL canary probes. Check real ECS task placement across three AZs; three available subnets or three desired tasks alone do not prove placement. Capture the committed canary digest and relevant timestamps before any RDS fault tests.

## Example canary exercise

From an approved HTTPS client, authenticate with a securely retrieved bearer token, then `PUT /canary/m3-before-failover` with `{"value":"before-failover-001"}`, and `GET` the same resource. Record the returned SHA-256 digest and verify it after the planned RDS failover. For an isolated backup restore, only compare transactions committed **before** the selected recovery point; a later transaction is not evidence of lost committed data in the backup.

Restrict ALB ingress to approved CIDRs. Do not paste tokens into source, workflow output, command histories, or shared logs.

## Offline tests

```bash
python3 -m unittest discover \
  -s tests/fixtures/deployment/postgres-canary-app/tests \
  -p 'test_*.py' -v
```

These tests use an in-memory fake store and a stub PostgreSQL module; they require no Docker, AWS, external Python packages or running database. They test the HTTP/auth/error contract and connection TLS options, **not** a real RDS connection. The existing Terraform Static Analysis workflow runs them.

**Retirement:** The two application secrets created manually in Secrets Manager and the SSM RDS-host parameter are not Terraform-managed and must be separately inventoried and disposed of (or deliberately retained) after testing. An applied `deployment_profile=production` requires the protected [production retirement procedure](../../../../docs/production-retirement.md). Do not switch the profile to development to destroy it or set `image_digest=null` to quiesce a running production-profile service.
