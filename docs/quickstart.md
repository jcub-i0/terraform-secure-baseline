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

## Prerequisites

This configuration requires (4) AWS accounts for each environment: `dev`, `staging`, `prod`, and `control-plane`.

Upon initial deployment, each AWS account must have an Admin-level IAM user with access keys configured. These access keys will be used by the AWS CLI. **We do NOT recommend using `root` user access keys.** 
> You can also create an Administrative IAM role dedicated to Terraform-use to avoid long-lived credentials. We are skipping this step and using an IAM user named `baseline-admin` to keep initial deployment as simple as possible.

Install and configure:

- Terraform
- AWS CLI
- Git
- Access to the required AWS accounts
- Admin-level IAM permissions to create AWS resources

Verify AWS CLI access:

```bash
aws sts get-caller-identity
```

---

## Clone Repository

```bash
git clone https://github.com/jcub-i0/terraform-secure-baseline.git
cd terraform-secure-baseline
```

---

## Configure AWS CLI Profiles

Create or configure AWS CLI profiles for each account.

Example profile names:

```text
control-plane
dev
staging
prod
```

Example: To create an AWS profile for the `dev` env, run the following:
```bash
aws configure --profile dev
```
> Answer the prompts accordingly:
> ```
> AWS Access Key ID: <admin-iam-user-access-key>
> AWS Secret Access Key: <admin-iam-user-secret-access-key>
> Default region name: us-east-1
> Default output format: json 
> ```
Repeat this process for each `env`.

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

This stack uses local Terraform state because it creates the remote backend resources. The `state` stack's local state can (and should) be migrated to a remote backend following initial deployment.

The `state` stack has (4) variables:

```
cloud_name
environment
primary_region
bucket_admin_principals
```
 
`bootstrap/state/terraform.tfvars` defines all but the `bucket_admin_principals` variable (type: `list(string)`).
 
It's highly recommended to add the ARNs of the administrative Terraform IAM user/role and the `root` user of the respective account to this variable. Otherwise, **the ability to modify S3 bucket policies may be lost** (this is by design -- security-by-default is highly emphasized.)

Example:

```
export TF_VAR_bucket_admin_principals='["arn:aws:iam::<account-id>:user/baseline-admin","arn:aws:iam::<account-id>:root"]'
```

Deploy `control-plane`'s `state` stack:

```bash
export AWS_PROFILE=control-plane

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

# Phase 2 - Deploy Control Plane Account Stack

The control-plane `account` stack creates `GitHub OIDC` roles for managing control-plane resources.

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

The control-plane account stack should generally be treated as manual/local-only because it creates the roles GitHub Actions uses to access the control plane.

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
- The bootstrap account is the management account
- `dev`, `staging`, and `prod` accounts have been invited and accepted into the organization

Then apply:

```bash
cd ../organizations
terraform init
terraform apply
```

---

# Phase 4 - Deploy Environment State Stacks

Each workload account needs its own Terraform backend resources.

Apply each environment `state` stack locally.

## Dev

```bash
export AWS_PROFILE=dev

cd ../../../bootstrap/dev/state
terraform init
terraform apply
```

## Staging

```bash
export AWS_PROFILE=staging

cd ../../staging/state
terraform init
terraform apply
```

## Prod

```bash
export AWS_PROFILE=prod

cd ../../prod/state
terraform init
terraform apply
```

Record each environment's state outputs:

```text
tf_state_bucket_arn
tf_state_bucket_cmk_arn
tf_state_lock_table_arn
```

These values are used by the corresponding `bootstrap/<env>/account` and `environments/<env>` stacks.

---

# Phase 5 - Deploy Environment Account Stacks

Each environment account stack creates the GitHub OIDC roles used by GitHub Actions for that environment.

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

# Phase 6 - Configure GitHub Environment Variables

Create GitHub environments for:

```text
dev-plan
dev
staging-plan
staging
prod-plan
prod
control-plane-plan
control-plane
```

Common variables may include:

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
```

Common secrets may include:

```text
ABUSEIPDB_API_KEY
```

Each GitHub environment should contain the variables appropriate for the AWS account and stack it manages.

---

# Phase 7 - Deploy Environment Baseline

Deploy each workload environment from the `environments/<env>` directory.

You can deploy locally or through GitHub Actions once OIDC roles and GitHub environment variables are configured.

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

Record environment outputs needed by the control-plane Identity Center stack, such as:

```text
logs_s3_readonly_policy_name
logs_cmk_decrypt_policy_name
secops_event_bus_arn
```

Exact output names may be environment-specific depending on the root module outputs.

---

# Phase 8 - Deploy IAM Identity Center

The Identity Center stack is deployed from the control plane.

It creates environment-specific groups, permission sets, and account assignments.

```bash
export AWS_PROFILE=bootstrap

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

If enabling optional Analyst or Engineer roles, pass the IAM policy names created by the environment baseline stacks.

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

# Phase 9 - Validate Deployment

After deployment completes, run the validation checklist:

```text
docs/validation-checklist.md
```

Recommended validation order:

1. Confirm Terraform state backends exist.
2. Confirm GitHub OIDC roles can be assumed.
3. Confirm baseline infrastructure exists in each environment.
4. Confirm Security Hub, GuardDuty, AWS Config, and CloudTrail are active.
5. Confirm SNS subscriptions are confirmed.
6. Run Lambda tests:
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
7. bootstrap/control_plane/identity_center
8. validation tests
```

---

## GitHub Actions

After GitHub OIDC roles and environment variables are configured, CI/CD can manage normal plan/apply/destroy operations.

Expected workflows:

| Workflow | Purpose |
|---------|---------|
| Terraform Plan | Runs plans for environment and control-plane stacks |
| Terraform Apply | Applies selected environment baseline |
| Terraform Destroy | Cleans up Identity Center attachments, then destroys selected environment baseline |

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

Review estimated costs before deploying all environments.

---

## Summary

This quickstart deploys `tf-secure-baseline` in the intended order:

- Bootstrap control-plane foundations
- Bootstrap environment backends and GitHub OIDC roles
- Deploy workload baselines
- Deploy centralized Identity Center access
- Validate security workflows

After completion, the platform provides a multi-account AWS security baseline with centralized identity, secure CI/CD, logging, detection, and event-driven response automation.