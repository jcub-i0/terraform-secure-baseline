# Quickstart - tf-secure-baseline

## Purpose

This guide provides the fastest practical path to deploying `tf-secure-baseline`.

It is intended to help users deploy the platform in the correct order and understand which stacks must be applied locally before GitHub Actions can manage the rest of the environment.

This guide covers:

- Initial AWS account setup
- Local bootstrap deployment
- Terraform backend creation
- GitHub OIDC role creation
- Environment baseline deployment
- Deployment profile and egress mode selection
- IAM Identity Center deployment
- Post-deployment validation

For a deeper explanation of the architecture, see:

```text
docs/architecture-overview.md
```

---

## Deployment Model

`tf-secure-baseline` uses a multi-account deployment model.

Expected AWS accounts:

```text
control-plane
dev
staging
prod
```

The repository is organized into three major deployment areas:

```text
bootstrap/control_plane
bootstrap/<env>
environments/<env>
```

At a high level:

| Area | Purpose |
|------|---------|
| `bootstrap/control_plane` | Centralized control plane resources |
| `bootstrap/<env>/state` | Two-phase bootstrap stack that creates its state bucket and CMK locally, then migrates its own state to S3 |
| `bootstrap/<env>/account` | Creates GitHub OIDC roles for an environment |
| `environments/<env>` | Deploys the full workload security baseline |

The `state` stacks are applied locally first because they create the remote backend resources that later Terraform stacks depend on. After each initial apply, its state is migrated to S3 with `scripts/bootstrap/migrate-state-stack.sh`.

---

## Deployment Profiles and Egress Modes

Before deploying an environment baseline, decide which deployment profile and egress mode should be used.

Deployment profiles provide cost/security defaults for each environment.

| `deployment_profile` | Default `egress_mode` | AWS Config | Backup | Inspector | CloudWatch retention | Intended use |
|---|---|---:|---:|---:|---:|---|
| `production` | `network_firewall` | Enabled | Enabled | Enabled | 90 days | Full security baseline for sensitive workloads |
| `development` | `nat_only` | Enabled | Disabled | Enabled | 30 days | Lower-cost development and testing |
| `minimal` | `vpc_endpoints_only` | Disabled | Disabled | Disabled | 14 days | Lowest-cost/private AWS-only testing |

The `egress_mode` controls private compute subnet outbound routing.

| `egress_mode` | Network Firewall | NAT Gateway | Compute private default route |
|---|---:|---:|---|
| `network_firewall` | Yes | Yes | Network Firewall endpoint |
| `nat_only` | No | Yes | NAT Gateway |
| `vpc_endpoints_only` | No | No | No default route |

Recommended starting values:

| Environment | Recommended `deployment_profile` | Recommended `egress_mode` |
|---|---|---|
| `dev` | `development` | `auto` |
| `staging` | `development` or `production` | `auto` |
| `prod` | `production` | `auto` |

When `egress_mode = "auto"`, the effective egress mode is selected from the deployment profile.

Example:

```hcl
deployment_profile = "development"
egress_mode        = "auto"
```

This resolves to:

```text
effective_egress_mode = nat_only
```

Important:

When `egress_mode = "vpc_endpoints_only"`, NAT Gateways and Network Firewall are not deployed, and private compute subnets do not receive a default internet route. This mode is intended for AWS-private testing or workloads that do not require external package repositories or third-party internet access. EC2 user data package installation may fail unless package access is provided another way.

---

## Prerequisites

This configuration requires **four AWS accounts**: `dev`, `staging`, `prod`, and `control-plane`.

Upon initial deployment, each AWS account must have an Admin-level IAM user with access keys configured. These access keys will be used by the AWS CLI. **We do NOT recommend using `root` user access keys.**

> Note: This example uses IAM user access keys for simplicity during initial bootstrap. If your organization uses AWS SSO or another federation method, configure the profiles using that method instead.

Install and configure:

- Terraform
- Git CLI
- `jq`
- A GitHub account with the following environments, if using `GitHub OIDC`:
  - control-plane
  - control-plane-plan
  - dev
  - dev-plan
  - staging
  - staging-plan
  - prod
  - prod-plan
- AWS CLI
- Admin-level IAM permissions in each account to create AWS resources

---

## Clone Repository

```bash
git clone https://github.com/jcub-i0/terraform-secure-baseline.git
cd terraform-secure-baseline
```

---

## Create Local Terraform Variable Files

The repository tracks `terraform.tfvars.example` templates instead of runtime `terraform.tfvars` files. Before running Terraform locally in a root that provides a template, copy it to `terraform.tfvars` and replace the example values with the correct deployment-specific configuration:

```bash
cp environments/dev/terraform.tfvars.example \
  environments/dev/terraform.tfvars
```

Repeat this for each Terraform root you plan to deploy. The resulting `terraform.tfvars` files are ignored by Git and must not be committed. GitHub Actions receives its values separately through workflow matrices, GitHub variables, and GitHub secrets.

---

## Configure AWS CLI Profiles

Create or configure AWS CLI profiles for each AWS account.

Because this deployment requires switching between multiple AWS accounts, it is recommended to use **four separate terminals**, each dedicated to a specific AWS account.

This reduces the chance of applying Terraform in the wrong account and also makes environment-specific variables easier to manage.

Whenever this guide says:

```bash
export AWS_PROFILE=<env>
```

interpret it as:

> Run the following commands from the terminal dedicated to that environment.

You may still run `export AWS_PROFILE=<env>` inside the dedicated terminal as an additional safety check.

Example profile names:

```text
control-plane
dev
staging
prod
```

---

### Create a Profile

Example: create an AWS CLI profile for the `dev` account.

```bash
aws configure --profile dev
```

Answer the prompts using credentials for the target account:

```text
AWS Access Key ID: <admin-iam-user-access-key>
AWS Secret Access Key: <admin-iam-user-secret-access-key>
Default region name: us-east-1
Default output format: json
```

Repeat this process for each AWS account.

> Note: This example uses IAM user access keys for simplicity during initial bootstrap. If your organization uses AWS SSO or another federation method, configure the profiles using that method instead.

---

### Verify Profiles

Verify each profile before deploying:

```bash
aws sts get-caller-identity --profile control-plane
aws sts get-caller-identity --profile dev
aws sts get-caller-identity --profile staging
aws sts get-caller-identity --profile prod
```

Confirm each command returns the expected AWS account ID.

---

# Phase 1 - Deploy and Migrate Control Plane State

The control-plane `state` stack creates the S3 bucket and KMS CMK used by the control-plane Terraform roots.

The initial apply must run without an active `bootstrap/control_plane/state/backend.tf`, because the backend does not exist yet. The repository instead tracks the intended post-migration configuration as:

```text
bootstrap/control_plane/state/backend.tf.migrated.example
```

Review that template before deployment and confirm its bucket, key, and region match the intended control-plane backend.

It is strongly recommended to include both the administrative Terraform IAM principal and the account root principal in `bucket_admin_principals`.

This variable defines which principals are allowed to modify protected state bucket controls, including the bucket policy, versioning configuration, and encryption configuration. If this list is empty or does not include the correct administrative principal, Terraform or account administrators may lose the ability to modify these settings.

From the repository root:

```bash
export AWS_PROFILE=control-plane
export TF_VAR_bucket_admin_principals='["arn:aws:iam::<control-plane-account-id>:user/baseline-admin","arn:aws:iam::<control-plane-account-id>:root"]'

terraform -chdir=bootstrap/control_plane/state init
terraform -chdir=bootstrap/control_plane/state apply
```

Record the outputs, especially:

```text
tf_state_bucket_name
tf_state_bucket_arn
tf_state_bucket_cmk_arn
```

Then migrate the state stack itself into the newly created backend:

```bash
AWS_PROFILE=control-plane \
EXPECTED_ACCOUNT_ID="<CONTROL-PLANE-ACCOUNT-ID>" \
./scripts/bootstrap/migrate-state-stack.sh control-plane
```

The helper validates the AWS identity and template, creates external backups, refuses to overwrite an existing remote state object, runs interactive `terraform init -migrate-state`, and verifies the remote state.

Verify an already-migrated stack at any time with:

```bash
AWS_PROFILE=control-plane \
EXPECTED_ACCOUNT_ID="<CONTROL-PLANE-ACCOUNT-ID>" \
./scripts/bootstrap/migrate-state-stack.sh control-plane --verify-only
```

Keep the migration backups until control-plane validation and the evidence workflow both succeed.

---

# Phase 2 - Deploy Control Plane Account Stack (Skip if not using `GitHub OIDC`)

The control-plane `account` stack creates `GitHub OIDC` roles for managing control-plane resources.

By default, the `account` stack's `enable_github_oidc` variable is set to `false` to preserve simplicity during initial deployments. If you wish to enable `GitHub OIDC`, set `enable_github_oidc` to `true`, along with other variables that `enable_github_oidc` depends on.

For more information regarding the `account` stack and `GitHub OIDC` integration, refer to the `README.md` documents, located at `bootstrap/<env>/account/README.md` and `modules/github_oidc/README.md`.

From the repository root:

```bash
terraform -chdir=bootstrap/control_plane/account init
terraform -chdir=bootstrap/control_plane/account apply
```

Record the outputs:

```text
plan_role_github_arn
apply_role_github_arn
```

Add these values to the appropriate GitHub environment variables for:

```text
control-plane-plan
control-plane
```

The control-plane `account` stack should generally be treated as manual/local-only because it creates the roles GitHub Actions uses to access the control plane.

---

# Phase 3 - Deploy AWS Organizations Structure

The `organizations` stack defines the AWS Organizations structure, including OUs such as:

```text
Workloads
NonProd
Prod
```

Before applying this stack, ensure:

- AWS Organizations is enabled in the bootstrap account
- The `control-plane` account is the management account
- `dev`, `staging`, and `prod` accounts have been invited and accepted into the organization

From the repository root:

```bash
terraform -chdir=bootstrap/control_plane/organizations init
terraform -chdir=bootstrap/control_plane/organizations apply
```

---

# Phase 4 - Deploy and Migrate Environment State Stacks

Each workload account needs its own Terraform backend resources.

Each state stack is applied locally first, without an active `backend.tf`, and then migrated into the S3 backend it created.

Before applying, review the tracked template for each environment:

```text
bootstrap/<env>/state/backend.tf.migrated.example
```

Confirm its bucket, key, and region match the intended environment. The migration helper refuses to continue if the template bucket does not match the state stack's `tf_state_bucket_name` output.

It is highly recommended to add the ARNs of the administrative Terraform IAM user or role and the account root principal to `bucket_admin_principals`. Otherwise, **the ability to modify protected S3 bucket controls may be lost**.

Run these commands from the repository root.

## Dev

```bash
export AWS_PROFILE=dev
export TF_VAR_bucket_admin_principals='["arn:aws:iam::<dev-account-id>:user/baseline-admin","arn:aws:iam::<dev-account-id>:root"]'

terraform -chdir=bootstrap/dev/state init
terraform -chdir=bootstrap/dev/state apply

EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
./scripts/bootstrap/migrate-state-stack.sh dev
```

## Staging

```bash
export AWS_PROFILE=staging
export TF_VAR_bucket_admin_principals='["arn:aws:iam::<staging-account-id>:user/baseline-admin","arn:aws:iam::<staging-account-id>:root"]'

terraform -chdir=bootstrap/staging/state init
terraform -chdir=bootstrap/staging/state apply

EXPECTED_ACCOUNT_ID="<STAGING-ACCOUNT-ID>" \
./scripts/bootstrap/migrate-state-stack.sh staging
```

## Prod

```bash
export AWS_PROFILE=prod
export TF_VAR_bucket_admin_principals='["arn:aws:iam::<prod-account-id>:user/baseline-admin","arn:aws:iam::<prod-account-id>:root"]'

terraform -chdir=bootstrap/prod/state init
terraform -chdir=bootstrap/prod/state apply

EXPECTED_ACCOUNT_ID="<PROD-ACCOUNT-ID>" \
./scripts/bootstrap/migrate-state-stack.sh prod
```

Record each environment's state outputs:

```text
tf_state_bucket_name
tf_state_bucket_arn
tf_state_bucket_cmk_arn
```

The generated active `bootstrap/<env>/state/backend.tf` files are ignored by Git. The tracked `backend.tf.migrated.example` files remain the source templates for new deployments and clean GitHub runners.

---

# Phase 5 - Deploy Environment Account Stacks (Skip if not using `GitHub OIDC`)

Each environment `account` stack creates the `GitHub OIDC` roles used by GitHub Actions for that environment.

By default, the `account` stack's `enable_github_oidc` variable is set to `false` to promote simplicity during initial deployments. If you wish to enable `GitHub OIDC`, set `enable_github_oidc` to `true`, along with other variables that `enable_github_oidc` depends on.

For more information regarding the `account` stack and `GitHub OIDC` integration, refer to the `README.md` documents located at `bootstrap/<env>/account/README.md` and `modules/github_oidc/README.md`.

Run these commands from the repository root.

## Dev

```bash
export AWS_PROFILE=dev

terraform -chdir=bootstrap/dev/account init
terraform -chdir=bootstrap/dev/account apply
```

## Staging

```bash
export AWS_PROFILE=staging

terraform -chdir=bootstrap/staging/account init
terraform -chdir=bootstrap/staging/account apply
```

## Prod

```bash
export AWS_PROFILE=prod

terraform -chdir=bootstrap/prod/account init
terraform -chdir=bootstrap/prod/account apply
```

Record the outputs from each account stack:

```text
plan_role_github_arn
apply_role_github_arn
```

Add these to the appropriate GitHub environment variables:

| GitHub Environment | Role Variable |
|-------------------|---------------|
| `dev-plan` | `PLAN_ROLE_GITHUB_ARN` |
| `dev` | `APPLY_ROLE_GITHUB_ARN` |
| `staging-plan` | `PLAN_ROLE_GITHUB_ARN` |
| `staging` | `APPLY_ROLE_GITHUB_ARN` |
| `prod-plan` | `PLAN_ROLE_GITHUB_ARN` |
| `prod` | `APPLY_ROLE_GITHUB_ARN` |

---

# Phase 6 - Configure GitHub Environment Variables (Skip if not using `GitHub OIDC`)

Workload deployment uses paired GitHub environments:

| Plan environment | Apply environment |
|---|---|
| `dev-plan` | `dev` |
| `staging-plan` | `staging` |
| `prod-plan` | `prod` |

The Plan environment runs before approval and exposes the Plan role. The Apply
environment should use required reviewers and exposes the Apply role only after
approval.

Configure the account-specific expected ID in both members of each pair:

```text
ACCOUNT_ID
```

For example, `dev-plan` and `dev` must both contain the `dev` AWS account ID.
This generic `ACCOUNT_ID` is used by workflow safety checks. It is separate
from the Terraform input variables `ACCOUNT_ID_DEV`, `ACCOUNT_ID_STAGING`, and
`ACCOUNT_ID_PROD`, which may still be required by the workload configuration.

Common variables may include:

```text
ACCOUNT_ID
PRIMARY_REGION
CLOUD_NAME
TF_STATE_BUCKET_ARN
TF_STATE_BUCKET_CMK_ARN
BUCKET_ADMIN_PRINCIPALS
ACCOUNT_ID_DEV
ACCOUNT_ID_STAGING
ACCOUNT_ID_PROD
SECOPS_EMAILS
BREAK_GLASS_TRUSTED_PRINCIPAL_ARNS
DEPLOYMENT_PROFILE
EGRESS_MODE
BRANCHES_PLAN_GITHUB
ALLOW_PULL_REQUESTS_PLAN_GITHUB
BRANCHES_APPLY_GITHUB
```

Role-specific variables:

| Environment type | Required role variable |
|---|---|
| `*-plan` | `PLAN_ROLE_GITHUB_ARN` |
| Apply environment | `APPLY_ROLE_GITHUB_ARN` |

The Apply environment also requires:

```text
STATE_STACK_BACKEND_KEY
```

`STATE_STACK_BACKEND_KEY` is used when the reconciliation Apply job
materializes the ignored state-stack `backend.tf` before strict post-apply
validation.

Secrets may include:

```text
ABUSEIPDB_API_KEY
```

Values used by both jobs—especially `ACCOUNT_ID`, `PRIMARY_REGION`,
`CLOUD_NAME`, and the Terraform state bucket and CMK ARNs—must match across
each Plan/Apply pair. The workflows validate the expected AWS account, but
operators should also keep all shared configuration synchronized.

Recommended environment defaults:

| Environment | `deployment_profile` | `egress_mode` |
|---|---|---|
| `dev` | `development` | `auto` |
| `staging` | `development` or `production` | `auto` |
| `prod` | `production` | `auto` |

---

# Phase 7 - Deploy Environment Baseline

After setting necessary variables for the workload environments (see `environments/<env>/variables.tf`), deploy each environment from the `environments/<env>` directory.

> If using `GitHub OIDC`, be sure to add the `apply_role_github_arn` output value to each environment's `bucket_admin_principals` variable.

You can deploy through GitHub Actions once OIDC roles and GitHub environment variables are configured or you can deploy locally if not.

When the `Terraform Apply` workflow is used, it does not immediately run
`terraform apply`. It first:

1. runs the Plan job through `<env>-plan` and the Plan role;
2. publishes the readable plan and uploads the saved plan artifact;
3. waits for approval on the protected `<env>` environment;
4. verifies the plan metadata and checksum; and
5. applies the exact saved plan through the Apply role.

The optional `reconcile_workload_account` input starts the plan-first
reconciliation workflow after a successful baseline apply.

Before applying, review the environment's profile settings:

```hcl
deployment_profile = "development"
egress_mode        = "auto"
```

The effective settings are exposed as Terraform outputs after deployment.

Run these commands from the repository root.

## Dev

```bash
export AWS_PROFILE=dev

terraform -chdir=environments/dev init
terraform -chdir=environments/dev plan
terraform -chdir=environments/dev apply
```

## Staging

```bash
export AWS_PROFILE=staging

terraform -chdir=environments/staging init
terraform -chdir=environments/staging plan
terraform -chdir=environments/staging apply
```

## Prod

```bash
export AWS_PROFILE=prod

terraform -chdir=environments/prod init
terraform -chdir=environments/prod plan
terraform -chdir=environments/prod apply
```

Record environment outputs needed by the
`bootstrap/control_plane/identity_center` stack, such as:

```text
logs_s3_readonly_policy_name
logs_cmk_decrypt_policy_name
secops_event_bus_arn
```

If using GitHub OIDC, the account reconciliation helper later reads
`lambda_cmk_arn` and `secrets_manager_cmk_arn` directly from the workload
Terraform state. Those CMK values do not need to be copied manually.

Also confirm the effective profile outputs:

```text
deployment_profile
egress_mode
effective_egress_mode
effective_cloudwatch_retention_days
effective_enable_config
effective_enable_rules
effective_backup_enabled
effective_inspector_enabled
```

These outputs confirm how profile defaults and explicit overrides resolved for the environment.

---

# Phase 8 - Reconcile Environment Account Stacks (Skip if not using `GitHub OIDC`)

After successfully applying each environment baseline, reconcile the current
workload-created Lambda and Secrets Manager CMK permissions into
`bootstrap/<env>/account`.

## GitHub Actions

The `Reconcile Workload Account` workflow supports:

```text
plan-only
plan-and-apply
```

`plan-only` generates the reconciliation plan, publishes the readable output,
and uploads the saved plan artifact without starting an Apply job.

`plan-and-apply` generates the plan first, then pauses on the protected
`dev`, `staging`, or `prod` environment. After approval, the Apply job
downloads and verifies the exact saved plan, applies it through the GitHub
Apply role, and runs strict workload bootstrap validation.

The plan is generated through the matching `*-plan` environment. Both the
Plan and Apply environments must contain the same generic `ACCOUNT_ID` for the
target AWS account.

The `Terraform Apply` workflow can invoke `plan-and-apply` automatically when
its `reconcile_workload_account` input is selected.

## Local Execution

The helper uses Terraform's normal variable-loading behavior for the account
stack, including `terraform.tfvars`, `*.auto.tfvars`, exported `TF_VAR_*`
variables, defaults, and optional `--var` or `--var-file` arguments. It
overrides only `lambda_cmk_arn` and `secrets_manager_cmk_arn` with the current
workload outputs.

For an exact plan review across two local invocations, save the plan explicitly
with `--plan-file`, then apply that same file with `--apply-plan`.

### Dev

```bash
DEV_RECONCILIATION_PLAN="/tmp/tf-secure-baseline-dev-account-reconciliation.tfplan"

AWS_PROFILE=dev \
EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
./scripts/bootstrap/reconcile-workload-account.sh dev \
  --plan-file="${DEV_RECONCILIATION_PLAN}"

AWS_PROFILE=dev \
EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
./scripts/bootstrap/reconcile-workload-account.sh dev \
  --apply-plan="${DEV_RECONCILIATION_PLAN}"
```

### Staging

```bash
STAGING_RECONCILIATION_PLAN="/tmp/tf-secure-baseline-staging-account-reconciliation.tfplan"

AWS_PROFILE=staging \
EXPECTED_ACCOUNT_ID="<STAGING-ACCOUNT-ID>" \
./scripts/bootstrap/reconcile-workload-account.sh staging \
  --plan-file="${STAGING_RECONCILIATION_PLAN}"

AWS_PROFILE=staging \
EXPECTED_ACCOUNT_ID="<STAGING-ACCOUNT-ID>" \
./scripts/bootstrap/reconcile-workload-account.sh staging \
  --apply-plan="${STAGING_RECONCILIATION_PLAN}"
```

### Prod

```bash
PROD_RECONCILIATION_PLAN="/tmp/tf-secure-baseline-prod-account-reconciliation.tfplan"

AWS_PROFILE=prod \
EXPECTED_ACCOUNT_ID="<PROD-ACCOUNT-ID>" \
./scripts/bootstrap/reconcile-workload-account.sh prod \
  --plan-file="${PROD_RECONCILIATION_PLAN}"

AWS_PROFILE=prod \
EXPECTED_ACCOUNT_ID="<PROD-ACCOUNT-ID>" \
./scripts/bootstrap/reconcile-workload-account.sh prod \
  --apply-plan="${PROD_RECONCILIATION_PLAN}"
```

The simpler `--apply` mode remains available. It generates a plan, displays it,
asks for confirmation, and applies that plan within the same invocation. A
separate earlier plan-only run is not reused unless `--plan-file` and
`--apply-plan` are used.

Use `--var-file <path>` when account inputs are stored in a custom variable
file that Terraform would not auto-load. Relative paths are resolved from the
selected `bootstrap/<env>/account` directory. Do not combine `--apply-plan`
with `--var` or `--var-file`; the reviewed saved plan already contains the
resolved input values.

Saved Terraform plan files may contain sensitive configuration values. Store
local plan files securely and remove them after the apply and validation
complete.

---

# Phase 9 - Deploy IAM Identity Center

The Identity Center stack is deployed from the control plane.

It creates environment-specific groups, permission sets, and account assignments.

Run these commands from the repository root:

```bash
export AWS_PROFILE=control-plane

terraform -chdir=bootstrap/control_plane/identity_center init
terraform -chdir=bootstrap/control_plane/identity_center apply
```

At minimum, this creates the SecOps Operator access model used for the rollback workflow.

Example groups:

```text
SecOps-Operator-Dev
SecOps-Operator-Staging
SecOps-Operator-Prod
```

If enabling optional `SecOps-Analyst` or `SecOps-Engineer` roles, pass the IAM policy names created by the environment baseline stacks.

Example:

```bash
export TF_VAR_logs_s3_readonly_policy_name_dev="<dev-logs-s3-readonly-policy-name>"
export TF_VAR_logs_cmk_decrypt_policy_name_dev="<dev-logs-cmk-decrypt-policy-name>"
export TF_VAR_enable_secops_analyst_dev=true
export TF_VAR_enable_secops_engineer_dev=true

terraform -chdir=bootstrap/control_plane/identity_center apply
```

This avoids circular dependencies by allowing environment stacks to create environment-specific IAM policies first, then allowing Identity Center to attach those policies by name/path.

---

# Phase 10 - Validate Deployment

After deployment completes, run the validation checklist:

```text
docs/validation-checklist.md
```

For release or client-readiness evidence, use `REQUIRE_STATE_STACK_REMOTE=true` for direct bootstrap and control-plane validation. The GitHub evidence workflows set this requirement to `true` by default.

Recommended validation order:

1. Verify every migrated state stack:
   ```bash
   AWS_PROFILE=control-plane ./scripts/bootstrap/migrate-state-stack.sh control-plane --verify-only
   AWS_PROFILE=dev ./scripts/bootstrap/migrate-state-stack.sh dev --verify-only
   AWS_PROFILE=staging ./scripts/bootstrap/migrate-state-stack.sh staging --verify-only
   AWS_PROFILE=prod ./scripts/bootstrap/migrate-state-stack.sh prod --verify-only
   ```
2. Run workload and control-plane bootstrap validation with `REQUIRE_STATE_STACK_REMOTE=true`.
3. Run the workload bootstrap, workload baseline, and control-plane evidence workflows.
4. Confirm GitHub OIDC roles can be assumed by running the applicable GitHub Actions workflows.
5. Confirm baseline infrastructure exists in each environment.
6. Confirm deployment profile outputs resolved correctly.
7. Confirm egress mode behavior:
   - `network_firewall`: Network Firewall and NAT Gateway are deployed, compute private default route points to firewall endpoints.
   - `nat_only`: Network Firewall is not deployed, NAT Gateway is deployed, compute private default route points to NAT.
   - `vpc_endpoints_only`: Network Firewall and NAT Gateway are not deployed, compute private subnets have no default route.
8. Confirm dedicated endpoint private subnets exist.
9. Confirm Interface VPC Endpoints are deployed into endpoint private subnets.
10. Confirm the S3 Gateway Endpoint is associated with the expected private route tables.
11. Confirm Security Hub, GuardDuty, AWS Config, and CloudTrail are active where expected by profile.
12. Confirm SNS subscriptions are confirmed.
13. Run Lambda tests:
    - `docs/lambda_tests/ec2_isolation.md`
    - `docs/lambda_tests/ec2_rollback.md`
    - `docs/lambda_tests/ip_enrichment.md`

---

## Deployment Order Summary

```text
1. Apply bootstrap/control_plane/state locally
2. Migrate bootstrap/control_plane/state with migrate-state-stack.sh
3. Deploy bootstrap/control_plane/account
4. Deploy bootstrap/control_plane/organizations
5. Apply each bootstrap/<env>/state locally
6. Migrate each bootstrap/<env>/state with migrate-state-stack.sh
7. Deploy bootstrap/<env>/account
8. Deploy environments/<env> locally or through the plan-first Terraform Apply workflow
9. Reconcile the workload account locally or through Reconcile Workload Account plan-and-apply
10. Deploy or re-apply bootstrap/control_plane/identity_center
11. Run validation and export evidence
```

---

## GitHub Actions

After GitHub OIDC roles and environment variables are configured, CI/CD can
manage normal plan/apply/destroy operations.

Expected workflows:

| Workflow | Purpose |
|---------|---------|
| Terraform Static Analysis | Runs static Terraform validation and scanning |
| Docs Validation | Runs documentation linting and link checks |
| Terraform Plan | Runs independent plans for environment and control-plane stacks |
| Terraform Apply | Generates and publishes a workload plan, waits for protected-environment approval, then applies the exact saved plan |
| Reconcile Workload Account | Runs `plan-only` or generates a reconciliation plan, waits for approval, applies the exact saved plan, and runs strict bootstrap validation |
| Terraform Destroy | Cleans up Identity Center attachments, then destroys the selected workload environment |
| Workload Bootstrap Evidence | Materializes the state backend, initializes workload roots, and exports bootstrap evidence |
| Workload Baseline Evidence | Exports the 14-script workload baseline evidence package |
| Control-Plane Evidence | Materializes the control-plane state backend, initializes control-plane roots, and exports control-plane evidence |

The standalone `Terraform Plan` workflow remains useful for pull requests,
pushes, and independent review. `Terraform Apply` generates its own plan in the
same workflow run so the protected Apply job can consume the exact artifact
that was presented for approval.

Plan jobs use `dev-plan`, `staging-plan`, or `prod-plan`; Apply jobs use the
matching protected `dev`, `staging`, or `prod` environment. Configure
`ACCOUNT_ID` in both members of each pair. The workflows validate the role ARN
account, the active AWS caller account, and the expected account stored in the
saved-plan metadata.

Saved binary plans are short-lived artifacts because Terraform plans can
contain sensitive values. Keep repository and workflow-run access limited to
trusted operators.

The destroy workflow first updates the Identity Center stack to remove
environment-specific policy attachments before destroying the workload
environment. This prevents IAM delete conflicts caused by Identity
Center-managed roles still attaching baseline-created IAM policies.

Evidence workflows use the read-only GitHub Plan roles. On clean runners, they
materialize the ignored runtime state-stack backend before initializing the
state stack. The evidence workflows require remote state by default.

---

## Important Notes

### State Stacks Use a Two-Phase Bootstrap Lifecycle

The first state-stack apply is local because the S3 backend does not exist yet.

After that initial apply, run:

```bash
./scripts/bootstrap/migrate-state-stack.sh <dev|staging|prod|control-plane>
```

The helper creates the ignored runtime `backend.tf`, migrates the local state, and verifies the remote object.

The tracked `backend.tf.migrated.example` files are templates, not proof that migration occurred. Use `--verify-only` or validation with `REQUIRE_STATE_STACK_REMOTE=true` to prove that the state is remotely readable.

State stacks are not normal GitHub apply targets. GitHub evidence workflows may initialize and read them, but the guarded initial migration remains a local administrative action.

---

### Account Stacks Should Be Modified Carefully

The `account` substacks create GitHub OIDC roles.

If these roles are destroyed or misconfigured, GitHub Actions may lose access to AWS.

The `bootstrap/control_plane/account` stack should generally be treated as manual/local-only.

---

### Identity Center Depends on Environment Policies

Some Identity Center permissions depend on IAM policies created by the environment baseline stacks.

This is expected.

The intended flow is:

```text
1. Deploy minimal Identity Center roles
2. Deploy environment baseline
3. Pass baseline-created policy names to Identity Center
4. Re-apply Identity Center
```

---

### Deployment Profiles Affect Resource Creation

Deployment profiles and egress modes affect which resources are created.

Examples:

- `production` with `egress_mode = "auto"` deploys Network Firewall and NAT Gateway.
- `development` with `egress_mode = "auto"` deploys NAT Gateway but not Network Firewall.
- `minimal` with `egress_mode = "auto"` does not deploy Network Firewall or NAT Gateway.

Always review the Terraform plan before applying a profile change, especially when switching between egress modes.

---

### Dedicated Endpoint Subnets

Interface VPC Endpoints are deployed into dedicated endpoint private subnets.

These subnets have their own route tables and do not require a default internet route.

Workloads reach Interface Endpoints over VPC-local routing and security group rules.

---

### Minimal Mode Has No General Internet Egress

When `egress_mode = "vpc_endpoints_only"`, private compute subnets do not have a default route to the internet.

This means workloads can reach configured AWS services through VPC endpoints, but they cannot reach:

- Operating system package repositories
- Public container registries
- External SaaS APIs
- Third-party internet services
- AWS services without configured VPC endpoints

Use this mode only when this behavior is acceptable or when another access path is intentionally provided.

---

### Cost Considerations

The baseline includes services that can create meaningful cost, especially when deployed across multiple environments.

Notable cost drivers include:

- AWS Network Firewall
- NAT Gateway
- VPC endpoints
- CloudWatch Logs
- VPC Flow Logs
- GuardDuty
- Security Hub
- Inspector
- KMS requests
- Backup storage

Deployment profiles and egress modes can reduce cost for non-production environments, but they also change security and connectivity behavior.

Review estimated costs before deploying all environments.

---

## Summary

This quickstart deploys `tf-secure-baseline` in the intended order:

- Bootstrap control-plane foundations
- Bootstrap environment backends and GitHub OIDC roles
- Deploy workload baselines
- Confirm deployment profile and egress mode behavior
- Deploy centralized Identity Center access
- Validate security workflows

After completion, the platform provides a multi-account AWS security baseline with centralized identity, secure CI/CD, logging, detection, configurable egress behavior, private VPC endpoint access, and event-driven response automation.

# Destruction / Cleanup Procedure

If you wish to destroy the infrastructure you created, the order in which you run `terraform destroy` is **VERY IMPORTANT**.

**Seriously** - this can **ruin your night.** Be sure to destroy resources in the correct order.

Destroying stacks out of order can cause failures such as:

- IAM policies failing to delete because Identity Center still has them attached
- GitHub Actions losing access because OIDC roles were destroyed too early
- Terraform state backend resources being destroyed before dependent stacks are removed

A migrated state stack must not destroy the S3 bucket that currently stores its own active state. Before destroying any `bootstrap/<env>/state` or `bootstrap/control_plane/state` stack, first migrate that stack's state back to local state or to another independent backend and retain an external backup.

Do not run `terraform destroy` against a state stack while its active backend still points to the bucket it manages.

---

## Single Environment Teardown

If you are only destroying one environment, do **not** destroy the entire Identity Center stack first.

Instead, first update the Identity Center stack to remove that environment’s optional policy attachments or role assignments.

Example for `dev`:

From the repository root:

```bash
export TF_VAR_enable_secops_analyst_dev=false
export TF_VAR_enable_secops_engineer_dev=false
export TF_VAR_logs_s3_readonly_policy_name_dev=""
export TF_VAR_logs_cmk_decrypt_policy_name_dev=""

terraform -chdir=bootstrap/control_plane/identity_center apply
```

Then destroy the selected environment in this order:

### Dev

Run from the repository root:

```bash
terraform -chdir=environments/dev destroy
terraform -chdir=bootstrap/dev/account destroy

STATE_DIR="bootstrap/dev/state"
terraform -chdir="${STATE_DIR}" state pull   > "${HOME}/tf-secure-baseline-dev-state-pre-destroy.json"
mv "${STATE_DIR}/backend.tf" "${STATE_DIR}/backend.tf.pre-destroy"
terraform -chdir="${STATE_DIR}" init -migrate-state
terraform -chdir="${STATE_DIR}" destroy
```

### Staging

Run from the repository root:

```bash
terraform -chdir=environments/staging destroy
terraform -chdir=bootstrap/staging/account destroy

STATE_DIR="bootstrap/staging/state"
terraform -chdir="${STATE_DIR}" state pull   > "${HOME}/tf-secure-baseline-staging-state-pre-destroy.json"
mv "${STATE_DIR}/backend.tf" "${STATE_DIR}/backend.tf.pre-destroy"
terraform -chdir="${STATE_DIR}" init -migrate-state
terraform -chdir="${STATE_DIR}" destroy
```

### Prod

Run from the repository root:

```bash
terraform -chdir=environments/prod destroy
terraform -chdir=bootstrap/prod/account destroy

STATE_DIR="bootstrap/prod/state"
terraform -chdir="${STATE_DIR}" state pull   > "${HOME}/tf-secure-baseline-prod-state-pre-destroy.json"
mv "${STATE_DIR}/backend.tf" "${STATE_DIR}/backend.tf.pre-destroy"
terraform -chdir="${STATE_DIR}" init -migrate-state
terraform -chdir="${STATE_DIR}" destroy
```

---

## Full Platform Teardown

If you are destroying the entire platform, use this order:

### 0. Identity Center

From the repository root:

```bash
terraform -chdir=bootstrap/control_plane/identity_center destroy
```

### Dev

1. `environments/dev`
2. `bootstrap/dev/account`
3. Migrate `bootstrap/dev/state` away from its self-managed S3 backend
4. Destroy `bootstrap/dev/state`

### Staging

5. `environments/staging`
6. `bootstrap/staging/account`
7. Migrate `bootstrap/staging/state` away from its self-managed S3 backend
8. Destroy `bootstrap/staging/state`

### Prod

9. `environments/prod`
10. `bootstrap/prod/account`
11. Migrate `bootstrap/prod/state` away from its self-managed S3 backend
12. Destroy `bootstrap/prod/state`

### Control Plane

13. `bootstrap/control_plane/organizations`
14. `bootstrap/control_plane/account`
15. Migrate `bootstrap/control_plane/state` away from its self-managed S3 backend
16. Destroy `bootstrap/control_plane/state`

---

## Important Notes

- Do **not** destroy `bootstrap/<env>/account` before `environments/<env>`.
  - The account stack contains the GitHub OIDC roles used by CI/CD.

- Do **not** destroy `bootstrap/<env>/state` before all stacks using that backend are destroyed.
  - The state stack contains the Terraform backend resources.

- Do **not** destroy `bootstrap/control_plane/account` before other control-plane substacks.
  - It contains the GitHub OIDC roles used to manage the control plane.

- Destroying `bootstrap/control_plane/state` should always be last.
  - It contains the backend resources for the control-plane stacks.
  - Migrate its state to local state or another independent backend before destroying the bucket it manages.

- Versioned state buckets may retain noncurrent state and lockfile object versions.
  - Preserve an external state backup and follow approved bucket-retention or cleanup controls before final deletion.