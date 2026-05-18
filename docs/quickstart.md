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
| `bootstrap/<env>/state` | Local bootstrap stack that creates remote state resources for an environment |
| `bootstrap/<env>/account` | Creates GitHub OIDC roles for an environment |
| `environments/<env>` | Deploys the full workload security baseline |

The `state` stacks are applied locally first because they create the remote backend resources that later Terraform stacks depend on.

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

# Phase 1 - Deploy Control Plane State

The control-plane `state` stack creates backend resources for the control-plane substacks.

This stack uses local Terraform state because it creates the remote backend resources. This local Terraform state can and should be migrated to a remote backend following initial deployment.

It's highly recommended to add the ARNs of the administrative Terraform IAM user/role and the `root` user of the respective account to the `bucket_admin_principals` variable. Otherwise, **the ability to modify S3 bucket policies may be lost**. This is an intended symptom of the configuration's security-by-default design.

```bash
export TF_VAR_bucket_admin_principals='["arn:aws:iam::<account-id>:user/baseline-admin","arn:aws:iam::<account-id>:root"]'
```

Deploy `control-plane`'s `state` stack:

```bash
export AWS_PROFILE=control-plane
export TF_VAR_bucket_admin_principals='["arn:aws:iam::<control-plane-account-id>:user/baseline-admin","arn:aws:iam::<control-plane-account-id>:root"]'

cd bootstrap/control_plane/state
terraform init
terraform apply
```

Record the outputs, especially:

```text
tf_state_bucket_arn
tf_state_bucket_cmk_arn
tf_state_lock_table_arn
```

These values are used by the other control-plane substacks.

---

# Phase 2 - Deploy Control Plane Account Stack (Skip if not using `GitHub OIDC`)

The control-plane `account` stack creates `GitHub OIDC` roles for managing control-plane resources.

By default, the `account` stack's `enable_github_oidc` variable is set to `false` to preserve simplicity during initial deployments. If you wish to enable `GitHub OIDC`, set `enable_github_oidc` to `true`, along with other variables that `enable_github_oidc` depends on.

For more information regarding the `account` stack and `GitHub OIDC` integration, refer to the `README.md` documents, located at `bootstrap/<env>/account/README.md` and `modules/github_oidc/README.md`.

From `bootstrap/control_plane/state`:

```bash
cd ../account
terraform init
terraform apply
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

Then apply from `bootstrap/control_plane/account`:

```bash
cd ../organizations
terraform init
terraform apply
```

---

# Phase 4 - Deploy Environment State Stacks

Each workload account needs its own Terraform backend resources.

Apply each environment `state` stack locally.

This stack uses local Terraform state because it creates the remote backend resources. This local Terraform state can and should be migrated to a remote backend following initial deployment.

It's highly recommended to add the ARNs of the administrative Terraform IAM user/role and the `root` user of the respective account to this variable. Otherwise, **the ability to modify S3 bucket policies may be lost**.

## Dev

```bash
export AWS_PROFILE=dev
export TF_VAR_bucket_admin_principals='["arn:aws:iam::<dev-account-id>:user/baseline-admin","arn:aws:iam::<dev-account-id>:root"]'

cd ../../../bootstrap/dev/state
terraform init
terraform apply
```

## Staging

```bash
export AWS_PROFILE=staging
export TF_VAR_bucket_admin_principals='["arn:aws:iam::<staging-account-id>:user/baseline-admin","arn:aws:iam::<staging-account-id>:root"]'

cd ../../staging/state
terraform init
terraform apply
```

## Prod

```bash
export AWS_PROFILE=prod
export TF_VAR_bucket_admin_principals='["arn:aws:iam::<prod-account-id>:user/baseline-admin","arn:aws:iam::<prod-account-id>:root"]'

cd ../../prod/state
terraform init
terraform apply
```

Record each environment's `state` outputs:

```text
tf_state_bucket_arn
tf_state_bucket_cmk_arn
tf_state_lock_table_arn
```

These values are used by the corresponding `bootstrap/<env>/account` and `environments/<env>` stacks.

---

# Phase 5 - Deploy Environment Account Stacks (Skip if not using `GitHub-OIDC`)

Each environment `account` stack creates the `GitHub OIDC` roles used by GitHub Actions for that environment.

By default, the `account` stack's `enable_github_oidc` variable is set to `false` to promote simplicity during initial deployments. If you wish to enable `GitHub OIDC`, set `enable_github_oidc` to `true`, along with other variables that `enable_github_oidc` depends on.

For more information regarding the `account` stack and `GitHub OIDC` integration, refer to the `README.md` documents located at `bootstrap/<env>/account/README.md` and `modules/github_oidc/README.md`.

## Dev

```bash
export AWS_PROFILE=dev

cd ../../dev/account
terraform init
terraform apply
```

## Staging

```bash
export AWS_PROFILE=staging

cd ../../staging/account
terraform init
terraform apply
```

## Prod

```bash
export AWS_PROFILE=prod

cd ../../prod/account
terraform init
terraform apply
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

Variables in each GitHub environment may include:

```text
PRIMARY_REGION
TF_STATE_BUCKET_ARN
TF_STATE_BUCKET_CMK_ARN
TF_STATE_LOCK_TABLE_ARN
BUCKET_ADMIN_PRINCIPALS
ACCOUNT_ID_DEV
ACCOUNT_ID_STAGING
ACCOUNT_ID_PROD
SECOPS_EMAILS
BREAK_GLASS_TRUSTED_PRINCIPAL_ARNS
DEPLOYMENT_PROFILE
EGRESS_MODE
```

Secrets may include:

```text
ABUSEIPDB_API_KEY
```

Each GitHub environment should contain the variables appropriate for the AWS account and stack it manages.

If deployment profile and egress mode are set through Terraform variable files instead of GitHub environment variables, make sure the configured values match the intended environment behavior.

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

Before applying, review the environment's profile settings:

```hcl
deployment_profile = "development"
egress_mode        = "auto"
```

The effective settings are exposed as Terraform outputs after deployment.

## Dev

```bash
export AWS_PROFILE=dev

cd ../../../environments/dev
terraform init
terraform plan
terraform apply
```

## Staging

```bash
export AWS_PROFILE=staging

cd ../staging
terraform init
terraform plan
terraform apply
```

## Prod

```bash
export AWS_PROFILE=prod

cd ../prod
terraform init
terraform plan
terraform apply
```

Record environment outputs needed by the `bootstrap/control-plane/identity_center` and, if using `GitHub OIDC`, `bootstrap/<env>/account` stacks, such as:

```text
logs_s3_readonly_policy_name
logs_cmk_decrypt_policy_name
secops_event_bus_arn
lambda_cmk_arn
secrets_manager_cmk_arn
```

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

# Phase 8 - Reapply `Account` Stacks (Skip if not using `GitHub OIDC`)

After successfully applying each environment's `baseline` stack, set the `lambda_cmk_arn` and `secrets_manager_cmk_arn` variables and reapply the `bootstrap/<env>/account` stacks for each environment.

## Dev

```bash
export AWS_PROFILE=dev

export TF_VAR_lambda_cmk_arn="<lambda_cmk_arn>"
export TF_VAR_secrets_manager_cmk_arn="<secrets_manager_cmk_arn>"
cd ../../bootstrap/dev/account
terraform apply
```

## Staging

```bash
export AWS_PROFILE=staging

export TF_VAR_lambda_cmk_arn="<lambda_cmk_arn>"
export TF_VAR_secrets_manager_cmk_arn="<secrets_manager_cmk_arn>"
cd ../../bootstrap/staging/account
terraform apply
```

## Prod

```bash
export AWS_PROFILE=prod

export TF_VAR_lambda_cmk_arn="<lambda_cmk_arn>"
export TF_VAR_secrets_manager_cmk_arn="<secrets_manager_cmk_arn>"
cd ../../bootstrap/prod/account
terraform apply
```

Be sure to also set these variables, `LAMBDA_CMK_ARN` and `SECRETS_MANAGER_CMK_ARN`, in the following GitHub environments:

```text
dev
dev-plan
prod
prod-plan
staging
staging-plan
```

Setting these variables in each GitHub environment grants GitHub roles required access, enabling CI/CD workflows to run error-free.

---

# Phase 9 - Deploy IAM Identity Center

The Identity Center stack is deployed from the control plane.

It creates environment-specific groups, permission sets, and account assignments.

```bash
export AWS_PROFILE=control-plane

cd ../../bootstrap/control_plane/identity_center
terraform init
terraform apply
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

terraform apply
```

This avoids circular dependencies by allowing environment stacks to create environment-specific IAM policies first, then allowing Identity Center to attach those policies by name/path.

---

# Phase 10 - Validate Deployment

After deployment completes, run the validation checklist:

```text
docs/validation-checklist.md
```

Recommended validation order:

1. Confirm Terraform state backends exist in each AWS account, including `control-plane`.
2. Confirm GitHub OIDC roles can be assumed by running a GitHub Actions workflow, if using `GitHub OIDC`.
3. Confirm baseline infrastructure exists in each environment.
4. Confirm deployment profile outputs resolved correctly.
5. Confirm egress mode behavior:
   - `network_firewall`: Network Firewall and NAT Gateway are deployed, compute private default route points to firewall endpoints.
   - `nat_only`: Network Firewall is not deployed, NAT Gateway is deployed, compute private default route points to NAT.
   - `vpc_endpoints_only`: Network Firewall and NAT Gateway are not deployed, compute private subnets have no default route.
6. Confirm dedicated endpoint private subnets exist.
7. Confirm Interface VPC Endpoints are deployed into endpoint private subnets.
8. Confirm S3 Gateway Endpoint is associated with the expected private route tables.
9. Confirm Security Hub, GuardDuty, AWS Config, and CloudTrail are active where expected by profile.
10. Confirm SNS subscriptions are confirmed.
11. Run Lambda tests:
    - `docs/lambda_tests/ec2_isolation.md`
    - `docs/lambda_tests/ec2_rollback.md`
    - `docs/lambda_tests/ip_enrichment.md`

---

## Deployment Order Summary

```text
1. bootstrap/control_plane/state
2. bootstrap/control_plane/account
3. bootstrap/control_plane/organizations
4. bootstrap/<env>/state
5. bootstrap/<env>/account
6. environments/<env>
7. bootstrap/<env>/account re-apply with defined CMK variables (if using GitHub OIDC)
8. bootstrap/control_plane/identity_center
9. validation tests
```

---

## GitHub Actions

After GitHub OIDC roles and environment variables are configured, CI/CD can manage normal plan/apply/destroy operations.

Expected workflows:

| Workflow | Purpose |
|---------|---------|
| Terraform Static Analysis | Runs static Terraform validation and scanning |
| Docs Validation | Runs documentation linting and link checks |
| Terraform Plan | Runs plans for environment and control-plane stacks |
| Terraform Apply | Applies selected environment baseline |
| Terraform Destroy | Cleans up Identity Center attachments, then destroys selected environment `baseline` |

The destroy workflow first updates the Identity Center stack to remove environment-specific policy attachments before destroying the baseline stack.

This prevents IAM delete conflicts caused by Identity Center-managed roles still attaching baseline-created IAM policies.

---

## Important Notes

### State Stacks Are Local Bootstrap Stacks

The `state` substacks should be applied locally.

They create the remote backend resources used by the other stacks.

Do not treat them like normal GitHub-managed stacks.

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

---

## Single Environment Teardown

If you are only destroying one environment, do **not** destroy the entire Identity Center stack first.

Instead, first update the Identity Center stack to remove that environment’s optional policy attachments or role assignments.

Example for `dev`:

```bash
cd bootstrap/control_plane/identity_center

export TF_VAR_enable_secops_analyst_dev=false
export TF_VAR_enable_secops_engineer_dev=false
export TF_VAR_logs_s3_readonly_policy_name_dev=""
export TF_VAR_logs_cmk_decrypt_policy_name_dev=""

terraform apply
```

Then destroy the selected environment in this order:

### Dev

```bash
cd environments/dev
terraform destroy

cd ../../bootstrap/dev/account
terraform destroy

cd ../state
terraform destroy
```

### Staging

```bash
cd environments/staging
terraform destroy

cd ../../bootstrap/staging/account
terraform destroy

cd ../state
terraform destroy
```

### Prod

```bash
cd environments/prod
terraform destroy

cd ../../bootstrap/prod/account
terraform destroy

cd ../state
terraform destroy
```

---

## Full Platform Teardown

If you are destroying the entire platform, use this order:

### 0. Identity Center

```bash
cd bootstrap/control_plane/identity_center
terraform destroy
```

### Dev

1. `environments/dev`
2. `bootstrap/dev/account`
3. `bootstrap/dev/state`

### Staging

4. `environments/staging`
5. `bootstrap/staging/account`
6. `bootstrap/staging/state`

### Prod

7. `environments/prod`
8. `bootstrap/prod/account`
9. `bootstrap/prod/state`

### Control Plane

10. `bootstrap/control_plane/organizations`
11. `bootstrap/control_plane/account`
12. `bootstrap/control_plane/state`

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