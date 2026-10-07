# Quickstart - tf-secure-baseline

## Purpose

This guide describes the deployment path for `tf-secure-baseline` at **v1.11.0-rc1**, commit `728166fa17bf42fe06bf540729c6aba1e70e05d5`. It is not a claim that a final v1.11.0 release has already been published.

Examples are for an authorized deployment with reviewed account-specific configuration. Public source visibility is not deployment permission; see [LICENSE](../LICENSE). This guide does not change the license or resolve ownership notices.

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
- Production retirement and destruction

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
security-operations
dev
staging
prod
```

The repository is organized into four major deployment areas:

```text
bootstrap/control_plane
bootstrap/security_operations
bootstrap/<env>
environments/<env>
```

At a high level:

| Area | Purpose |
|------|---------|
| `bootstrap/control_plane` | AWS Organizations, Identity Center, control-plane state, and control-plane OIDC resources |
| `bootstrap/security_operations` | Security-operations state/OIDC resources and centralized Security Hub, GuardDuty, and Security Hub V2 administration |
| `bootstrap/<env>/state` | Two-phase bootstrap stack that creates its state bucket and CMK locally, then migrates its own state to S3 |
| `bootstrap/<env>/account` | Creates GitHub OIDC roles for a workload environment |
| `environments/<env>` | Deploys the workload-local security baseline |

The `state` stacks are applied locally first because they create the remote backend resources that later Terraform stacks depend on. After each initial apply, its state is migrated to S3 with `scripts/bootstrap/migrate-state-stack.sh`.

---

## Deployment Profiles and Egress Modes

Before deploying an environment baseline, decide which deployment profile and egress mode should be used.

Deployment profiles provide cost/security defaults and production resilience policy. The table below shows defaults, not proof of live controls or a complete compliance program. Inspect effective Terraform outputs and the supported overrides before relying on any setting.

| `deployment_profile` | Default `egress_mode` | AWS Config | Backup scheduling | Inspector | GuardDuty Fargate Runtime Monitoring | CloudWatch retention | Intended use |
|---|---|---:|---:|---:|---:|---:|---|
| `production` | `network_firewall` | Enabled | Enabled | Enabled | Enabled | 90 days | Full security baseline for sensitive workloads |
| `development` | `nat_only` | Enabled | Disabled | Enabled | Enabled | 30 days | Lower-cost development and testing with production-aligned runtime detection |
| `minimal` | `vpc_endpoints_only` | Disabled | Disabled | Disabled | Disabled | 14 days | Lowest-cost/private AWS-only testing |

GuardDuty Fargate Runtime Monitoring is derived directly from `deployment_profile` in RC1; there is no independent top-level Runtime Monitoring enable/disable input. `production` and `development` set the workload ECS cluster to `GuardDutyManaged=true`, while `minimal` sets `GuardDutyManaged=false`.

The Backup column refers to scheduled AWS Backup behavior. The encrypted environment backup vault and backup CMK are retained even when scheduling is disabled. When backups are disabled, the effective schedule and retention outputs are `null`, the backup plan/selection are absent, and workload EC2/RDS resources use `Backup=false`. Production defaults to `cron(0 5 * * ? *)` with 30-day retention. If backups are explicitly enabled for a non-production profile, the same default schedule is used with 7-day retention unless overridden.

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
| `staging` | `development` for this quickstart; review retirement limitations before choosing `production` | `auto` |
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

## v1.11 Topology, Regions, and Resilience

### Service region versus Terraform state region

These are distinct contracts:

| Setting | Authority and effect |
|---|---|
| Workload/account `primary_region` | AWS service/provider region; provider-backed assertions reject a mismatch where implemented |
| State-root `state_region` | Region used to create the state S3 bucket and CMK; default `us-east-1` |
| S3 backend `region` | Explicit backend configuration; it is not automatically rewritten when either Terraform variable changes |
| Validator/reconciliation `AWS_REGION` | Service region for those operations; state checks use independently resolved backend context |
| Migration helper `AWS_REGION` | Backend-region context; when supplied, it must match the tracked migration template |

All five RC1 state templates use `us-east-1`. A service-region change does not move state, the bucket, or the CMK. State/account/workload roots must use their intended backend bucket with distinct keys. See the [state module](../modules/state/README.md) and [bootstrap helper reference](../scripts/bootstrap/README.md).

In the commands below, `SERVICE_REGION` and `STATE_REGION` are **shell example variables**, not additional GitHub settings. Set them for the account/stack in the current terminal. `us-east-1` is the example used here, not evidence of alternate-region or multi-region disaster-recovery qualification:

```bash
export SERVICE_REGION="us-east-1"
export STATE_REGION="us-east-1"
export AWS_REGION="$SERVICE_REGION"
export AWS_DEFAULT_REGION="$SERVICE_REGION"
umask 077
```

Set `primary_region` in each service/account root's actual Terraform inputs and `state_region` in each state root's inputs. Keep them consistent with the intended provider/backend context. Setting a shell variable alone does not rewrite an existing `terraform.tfvars` or backend file. Review inherited `TF_VAR_*` values when switching accounts.

### Workload CIDR and Availability Zones

The workload roots defer a null `main_vpc_cidr` to the baseline's `10.0.0.0/16` default. The baseline accepts a canonical IPv4 **/16** and derives seven **/24** subnet families when `subnet_cidrs=null`:

```text
ingress_public       ALB placement and VPC-local traffic to targets
egress_public        NAT placement and same-AZ firewall return routing
compute_private      EC2 and ECS/Fargate tasks
data_private         RDS DB subnet group
serverless_private   VPC-attached response Lambdas
firewall_private     Network Firewall endpoints
endpoint_private     Interface VPC Endpoints
```

Production defaults to three AZs (21 subnets); development/minimal default to two (14 subnets). Baseline sorts the provider's standard AZ names filtered by `opt-in-status=opt-in-not-required`, then selects the profile count. Explicit AZs must be unique and belong to that eligible set. Additional AZs require matching explicit subnet CIDRs for all seven families.

For a new development portability deployment, a valid input excerpt is:

```hcl
primary_region     = "us-east-1"
deployment_profile = "development"
main_vpc_cidr      = "172.16.0.0/16"
azs                = null
subnet_cidrs       = null
```

Apply it through the actual effective variable inputs, not a second conflicting service map. All explicit subnet CIDRs must remain unique canonical /24s inside the chosen /16. Changing CIDRs, subnet roles, or AZ ordering in an existing environment is not a guaranteed non-disruptive migration; review replacements before applying.

In `network_firewall` mode the compute default route and egress-public return route use the same-AZ firewall endpoint, with same-AZ NAT. The ALB uses the separate ingress-public tier and reaches tasks over VPC-local routing. The baseline does not claim all private-tier or AWS-service traffic traverses Network Firewall. See the [networking reference](../modules/networking/README.md).

### Production behavior and limits

Normal production resolves RDS Multi-AZ and enables native RDS/ALB/Network Firewall deletion protection where those resources exist; ECR/ECS force deletion and Backup vault force destruction resolve to `false`. RDS remains a PostgreSQL DB instance, not Aurora or a Multi-AZ DB cluster. RDS-native automated-backup retention remains 14 days; AWS Backup scheduling/retention is a separate contract.

Restore Testing is derived from production and effective backup enablement. The configured test restores privately with `multiAz=false`, using the source RDS subnet group and data SG; this does not change the source database's production Multi-AZ posture. A configured restore plan is not evidence of an executed restore or application-data correctness. See [Backup](../modules/backup/README.md).

Deployable production ECS services require at least **two** fixed tasks or an autoscaling minimum of two outside retirement. The shipped production sample chooses three. Baseline enables service AZ rebalancing; one live task in every AZ must be checked separately. Normal runtime validation requires deployment-health settings `100` minimum and at least `200` maximum.

The production profile does not enable every possible protection. In particular, the logs bucket retains `force_destroy=true`, `prevent_destroy=false`, and Object Lock disabled; Network Firewall policy/subnet change protections remain disabled. See [storage limits](../modules/storage/README.md) and [firewall limits](../modules/firewall/README.md).

**Retirement scope:** baseline production policy is profile-driven, but the complete RC1 retirement workflow/durable cleanup supports **environment `prod` only**. Do not assume a production-profile `staging` or `dev` deployment has the same end-to-end automated teardown path. Do not bypass the limitation by changing its profile during destruction.

## Prerequisites

This configuration requires **five AWS accounts**: `control-plane`, `security-operations`, `dev`, `staging`, and `prod`.

Initial bootstrap needs an authorized AWS credential chain with sufficient administrative permissions in each target account. A dedicated IAM user with long-lived keys is **not** a repository requirement: an existing federated/assumed-role profile can be used. Do not use root access keys. Access through an Identity Center instance that has not yet been established cannot be assumed for the first bootstrap.

> Use the credential method approved by your organization and verify the actual caller before every stack change. Naming a profile does not prove its account or permissions.

Install and configure:

- Terraform **1.15.8**, matching RC1 root constraints and workflow tooling
- The committed root-specific provider lockfiles; AWS is pinned to **6.66.0** in the inspected RC1 roots
- Git CLI
- `jq`
- A GitHub account with the following environments, if using `GitHub OIDC`:
  - control-plane
  - control-plane-plan
  - security-operations-plan
  - dev
  - dev-plan
  - staging
  - staging-plan
  - prod
  - prod-plan
- AWS CLI
- Administrative authority appropriate to each bootstrap root
- For application image publication: Docker and `docker-credential-ecr-login`, in addition to AWS CLI and `jq`

Configure required reviewers and applicable branch restrictions on the protected GitHub Environments. A workflow’s `environment:` assignment selects an environment; the YAML alone does not prove human approval is required in repository settings. Keep lockfiles tracked and do not use `terraform init -upgrade` as a routine bootstrap step.

---

## Clone Repository

```bash
git clone https://github.com/jcub-i0/terraform-secure-baseline.git
cd terraform-secure-baseline
git checkout --detach v1.11.0-rc1
test "$(git rev-parse HEAD)" = "728166fa17bf42fe06bf540729c6aba1e70e05d5"
```

This pins the implementation used by this guide. Subsequent documentation-only commits can be layered onto that source; do not move the RC1 tag.

---

## Create Local Terraform Variable Files

The repository tracks `terraform.tfvars.example` templates instead of runtime `terraform.tfvars` files. Before running Terraform locally in a root that provides a template, copy it to `terraform.tfvars` and replace the example values with the correct deployment-specific configuration:

```bash
if [[ ! -e environments/dev/terraform.tfvars ]]; then
  cp environments/dev/terraform.tfvars.example environments/dev/terraform.tfvars
else
  printf '%s\n' 'Existing dev Terraform inputs retained; review them instead of overwriting.'
fi
```

Repeat this for each Terraform root you plan to deploy. The resulting `terraform.tfvars` files are ignored by Git and must not be committed. GitHub Actions receives its values separately through workflow matrices, GitHub variables, and GitHub secrets.

For local workload deployment, set `isolation_allowed` explicitly according to the approved environment policy. Do not infer a universal value from the profile or old instructions: the reusable baseline defaults to `false`, but the RC1 production environment root defaults to `true`. Workflow planning requires an explicit `ISOLATION_ALLOWED=true` or `false`. The canonical severity input defaults to `["CRITICAL"]` and accepts only `HIGH`/`CRITICAL`; review the response-automation contract before enabling automatic containment.

Templates contain example account IDs and names, not credentials or permission to use those accounts. Review existing backend files as well as `terraform.tfvars.example`; naming inputs do not automatically rewrite tracked backends. Preserve the one canonical `container-workloads.auto.tfvars.json` per workload and do not introduce a conflicting `ecs_services` value in another input source.

---

## Configure AWS CLI Profiles

Create or configure AWS CLI profiles for each AWS account.

Because this deployment requires switching between multiple AWS accounts, it is recommended to use **five separate terminals**, each dedicated to a specific AWS account.

This reduces the chance of applying Terraform in the wrong account and also makes environment-specific variables easier to manage.

Whenever this guide says:

```bash
export AWS_PROFILE="dev"  # Substitute the intended account profile.
```

interpret it as:

> Run the following commands from the terminal dedicated to that environment.

Set `AWS_PROFILE`, `AWS_REGION`, and `AWS_DEFAULT_REGION` explicitly in that terminal, and verify the caller with STS. Separate terminals reduce accidental context reuse but are not an authorization control.

Example profile names:

```text
control-plane
security-operations
dev
staging
prod
```

---

### Create a Profile

Use an existing organization-approved AWS CLI profile or configure the appropriate federation/assumed-role method for that account. This guide does not require new IAM user keys.

For an account whose approved bootstrap process specifically uses IAM user keys, the CLI configuration command is:

```bash
aws configure --profile dev
```

Supply the authorized account's credentials and intended default region, not root keys. For federated credentials, use that profile's supported login process instead. The rest of this guide relies on the resulting credential chain, not one particular credential source.

---

### Verify Profiles

Verify each profile before deploying:

```bash
aws sts get-caller-identity --profile control-plane
aws sts get-caller-identity --profile security-operations
aws sts get-caller-identity --profile dev
aws sts get-caller-identity --profile staging
aws sts get-caller-identity --profile prod
```

Confirm each command returns the expected AWS account ID and caller ARN. Stop on a mismatch. `EXPECTED_ACCOUNT_ID` is enforced by scripts that consume it; exporting that variable alone does not add an account assertion to every direct Terraform command.

Unless a section explicitly says migration/backend context, local examples use `AWS_REGION="$SERVICE_REGION"` and Terraform inputs with the same `primary_region`. State-root provisioning uses its own `state_region`. Plain interactive `terraform apply` below creates a fresh plan and asks for approval; it does not apply a separate earlier unsaved `terraform plan`. GitHub Actions is the supported reviewed saved-plan path described later.

---

# Phase 1 - Deploy and Migrate Control Plane State

The control-plane `state` stack creates the S3 bucket and KMS CMK used by the control-plane Terraform roots.

The initial apply must run without an active `bootstrap/control_plane/state/backend.tf`, because the backend does not exist yet. The repository instead tracks the intended post-migration configuration as:

```text
bootstrap/control_plane/state/backend.tf.migrated.example
```

Review that template before deployment and confirm its bucket, key, and region match the intended control-plane backend.

It is strongly recommended to include both the administrative Terraform IAM principal and the account root principal in `bucket_admin_principals`.

This variable identifies principals exempted from the state bucket’s policy/versioning/encryption-change denies; it does not itself grant their IAM permissions. Include the actual administrative principal. A root principal in a bucket policy is not a request to create or use root access keys. The root input rejects an empty list.

From the repository root:

```bash
export AWS_PROFILE=control-plane
export AWS_REGION="$SERVICE_REGION"
export AWS_DEFAULT_REGION="$AWS_REGION"
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
AWS_REGION="${STATE_REGION}" \
./scripts/bootstrap/migrate-state-stack.sh control-plane
```

The helper validates the AWS identity and template, creates external backups, checks the destination key, runs interactive `terraform init -migrate-state`, and verifies remote state/resource addresses. It refuses a destination object that `head-object` can read, but an access error is not independent proof that the key is unused; resolve permission ambiguity before approving migration. It requires the default workspace and compares the active backend file with the tracked template. See [state migration details](../scripts/bootstrap/README.md).

Verify an already-migrated stack at any time with:

```bash
AWS_PROFILE=control-plane \
EXPECTED_ACCOUNT_ID="<CONTROL-PLANE-ACCOUNT-ID>" \
AWS_REGION="${STATE_REGION}" \
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

The `organizations` stack defines the AWS Organizations structure and centralized-security prerequisites.

The intended OU/account placement is:

```text
Root
├── Workloads
│   ├── NonProd
│   │   ├── dev
│   │   └── staging
│   └── Prod
│       └── prod
└── Security
    └── security-operations
```

Before applying this stack, ensure:

- AWS Organizations is enabled in all-features mode in the `control-plane` management account
- `security-operations`, `dev`, `staging`, and `prod` are active organization member accounts
- the intended account IDs and account names are configured correctly

This stack owns the Organization resource, OUs, and organization-level prerequisites for centralized security, including Security Hub and GuardDuty trusted access/delegated administration, GuardDuty Malware Protection trusted access, and Security Hub V2 prerequisites. It does **not** declare member-account creation or account-move resources. Arrange the existing accounts under the intended OUs and verify placement through control-plane validation.

If the Organization, OUs, or other managed resources already exist outside this Terraform state, establish the appropriate reviewed adoption/import plan first. The stack is not a discovery-only wrapper around an existing Organization, and its Organization resource has `prevent_destroy=true`. Do not blindly apply or destroy it as part of a workload deployment.

From the repository root:

```bash
terraform -chdir=bootstrap/control_plane/organizations init
terraform -chdir=bootstrap/control_plane/organizations apply
```

---

# Phase 4 - Deploy and Migrate Security-Operations State

The `security-operations` account uses its own two-phase state bootstrap.

Review:

```text
bootstrap/security_operations/state/backend.tf.migrated.example
```

Then apply and migrate the state stack:

```bash
export AWS_PROFILE=security-operations
export AWS_REGION="$SERVICE_REGION"
export AWS_DEFAULT_REGION="$AWS_REGION"
export TF_VAR_bucket_admin_principals='["arn:aws:iam::<security-operations-account-id>:user/baseline-admin","arn:aws:iam::<security-operations-account-id>:root"]'

terraform -chdir=bootstrap/security_operations/state init
terraform -chdir=bootstrap/security_operations/state apply

EXPECTED_ACCOUNT_ID="<SECURITY-OPERATIONS-ACCOUNT-ID>" \
AWS_REGION="${STATE_REGION}" \
./scripts/bootstrap/migrate-state-stack.sh security-operations
```

Record:

```text
tf_state_bucket_name
tf_state_bucket_arn
tf_state_bucket_cmk_arn
```

---

# Phase 5 - Deploy Security-Operations Account Stack (Skip if not using `GitHub OIDC`)

This stack creates the security-operations GitHub OIDC roles. It remains separate from `security_services` so centralized security changes cannot remove the CI/CD roles used to inspect them.

```bash
export AWS_PROFILE=security-operations
export AWS_REGION="$SERVICE_REGION"
export AWS_DEFAULT_REGION="$AWS_REGION"

terraform -chdir=bootstrap/security_operations/account init
terraform -chdir=bootstrap/security_operations/account apply
```

Record the Plan role ARN. The current Terraform Plan and Export Security Operations Evidence workflows use the `security-operations-plan` GitHub Environment.

The general-purpose Terraform Apply and Terraform Destroy workflows remain workload-scoped; centralized security services are not part of routine workload lifecycle automation.

---

# Phase 6 - Deploy Centralized Security Services

The `bootstrap/security_operations/security_services` stack configures the delegated-administrator side of the centralized security model established by the control plane.

Before applying, copy and review its variable template and confirm the centralized rollout settings. The intended centralized deployment enables:

```text
enable_securityhub_organization_configuration = true
enable_guardduty_organization_configuration    = true
enable_securityhub_v2_organization_policy      = true
```

Also configure `securityhub_cspm_account_policies` for the workload accounts that should receive central Security Hub CSPM policies. The centralized GuardDuty contract retained in RC1 is:

```text
RUNTIME_MONITORING           = ALL
ECS_FARGATE_AGENT_MANAGEMENT = ALL
EC2_AGENT_MANAGEMENT         = ALL
EKS_ADDON_MANAGEMENT         = NONE
```

These organization settings are owned by the `security-operations` stack. Workload Terraform does not recreate them; workload stacks express cluster participation, task-execution IAM, networking, and validation expectations. Override the GuardDuty organization feature map only when the deployment intentionally requires a different organization policy.

Apply locally:

```bash
export AWS_PROFILE=security-operations
export AWS_REGION="$SERVICE_REGION"
export AWS_DEFAULT_REGION="$AWS_REGION"

terraform -chdir=bootstrap/security_operations/security_services init
terraform -chdir=bootstrap/security_operations/security_services plan
terraform -chdir=bootstrap/security_operations/security_services apply
```

At this stage, central Security Hub CSPM policy associations can exist before workload-local AWS Config has been deployed. AWS may report an association as pending or failed because standards cannot be enabled until Config is recording in the target account. Treat final association health as a post-workload validation condition rather than changing the deployment order.

The workload environment roots are configured to defer local Security Hub CSPM, GuardDuty, and Security Hub V2 ownership to this centralized layer.

---

# Phase 7 - Deploy and Migrate Environment State Stacks

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
export AWS_REGION="$SERVICE_REGION"
export AWS_DEFAULT_REGION="$AWS_REGION"
export TF_VAR_bucket_admin_principals='["arn:aws:iam::<dev-account-id>:user/baseline-admin","arn:aws:iam::<dev-account-id>:root"]'

terraform -chdir=bootstrap/dev/state init
terraform -chdir=bootstrap/dev/state apply

EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
AWS_REGION="${STATE_REGION}" \
./scripts/bootstrap/migrate-state-stack.sh dev
```

## Staging

```bash
export AWS_PROFILE=staging
export AWS_REGION="$SERVICE_REGION"
export AWS_DEFAULT_REGION="$AWS_REGION"
export TF_VAR_bucket_admin_principals='["arn:aws:iam::<staging-account-id>:user/baseline-admin","arn:aws:iam::<staging-account-id>:root"]'

terraform -chdir=bootstrap/staging/state init
terraform -chdir=bootstrap/staging/state apply

EXPECTED_ACCOUNT_ID="<STAGING-ACCOUNT-ID>" \
AWS_REGION="${STATE_REGION}" \
./scripts/bootstrap/migrate-state-stack.sh staging
```

## Prod

```bash
export AWS_PROFILE=prod
export AWS_REGION="$SERVICE_REGION"
export AWS_DEFAULT_REGION="$AWS_REGION"
export TF_VAR_bucket_admin_principals='["arn:aws:iam::<prod-account-id>:user/baseline-admin","arn:aws:iam::<prod-account-id>:root"]'

terraform -chdir=bootstrap/prod/state init
terraform -chdir=bootstrap/prod/state apply

EXPECTED_ACCOUNT_ID="<PROD-ACCOUNT-ID>" \
AWS_REGION="${STATE_REGION}" \
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

# Phase 8 - Deploy Environment Account Stacks (Skip if not using `GitHub OIDC`)

Each workload `account` stack creates the GitHub OIDC execution roles used by GitHub Actions for that environment. When image publication is enabled, the stack creates three distinct authorities: a Plan role, an Apply role, and an Image Publisher role.

The roles are intentionally separated:

| Role | Primary purpose | Trust model |
|---|---|---|
| Plan role | Terraform planning and validation/evidence operations | `repo:<owner>/<repo>:environment:<env>-plan` |
| Apply role | Apply reviewed workload plans | Configure the matching `<env>` GitHub Environment subject for this workflow path; the module also supports branch trust when no Apply environment is supplied |
| Image Publisher role | Publish/query application images in the environment ECR registry | Exact branch-based GitHub OIDC subjects |

The Image Publisher role is not an application deployment role. It does not receive broad ECS, IAM, Terraform state, or administrator permissions.

Run the account stack from the repository root for each workload environment:

## Dev

```bash
export AWS_PROFILE=dev
export AWS_REGION="$SERVICE_REGION"
export AWS_DEFAULT_REGION="$AWS_REGION"
terraform -chdir=bootstrap/dev/account init
terraform -chdir=bootstrap/dev/account apply
```

## Staging

```bash
export AWS_PROFILE=staging
export AWS_REGION="$SERVICE_REGION"
export AWS_DEFAULT_REGION="$AWS_REGION"
terraform -chdir=bootstrap/staging/account init
terraform -chdir=bootstrap/staging/account apply
```

## Prod

```bash
export AWS_PROFILE=prod
export AWS_REGION="$SERVICE_REGION"
export AWS_DEFAULT_REGION="$AWS_REGION"
terraform -chdir=bootstrap/prod/account init
terraform -chdir=bootstrap/prod/account apply
```

Record the role outputs:

```text
plan_role_github_arn
apply_role_github_arn
image_publisher_role_github_arn
```

The Plan and Apply role ARNs belong in the corresponding GitHub Environments. The Image Publisher role ARN belongs in the matching `*-plan` environment because `Deploy Application` uses that environment only to resolve configuration before its publisher job assumes the branch-trusted role.

For more detail, see `bootstrap/<env>/account/README.md` and `modules/github_oidc/README.md`.

# Phase 9 - Configure GitHub Environment Variables (Skip if not using `GitHub OIDC`)

Workload Terraform uses paired GitHub Environments for Plan and Apply:

| Plan environment | Apply environment |
|---|---|
| `dev-plan` | `dev` |
| `staging-plan` | `staging` |
| `prod-plan` | `prod` |

Centralized security planning/evidence uses `security-operations-plan`.

At minimum, each workload `*-plan` environment must provide the values required by the workload plan path, including `ACCOUNT_ID`, `PRIMARY_REGION`, `CLOUD_NAME`, `PLAN_ROLE_GITHUB_ARN`, `DEPLOYMENT_PROFILE`, and the other Terraform inputs used by that environment. `DEPLOYMENT_PROFILE` is required and must resolve to one of `production`, `development`, or `minimal`; the Plan path fails closed when it is missing or invalid.

Each protected Apply environment provides the Apply-specific values including `APPLY_ROLE_GITHUB_ARN`. Shared values such as `ACCOUNT_ID`, `PRIMARY_REGION`, `CLOUD_NAME`, `TF_STATE_BUCKET_ARN`, and `TF_STATE_BUCKET_CMK_ARN` must remain synchronized across each Plan/Apply pair.

For application image publication, configure these variables in the matching workload `*-plan` environment:

```text
ACCOUNT_ID
PRIMARY_REGION
CLOUD_NAME
IMAGE_PUBLISHER_ROLE_GITHUB_ARN
BRANCHES_IMAGE_PUBLISHER_GITHUB
```

`BRANCHES_IMAGE_PUBLISHER_GITHUB` is a JSON array of allowed branch names, for example:

```json
["main"]
```

The `Deploy Application` publisher job deliberately does **not** declare a GitHub `environment:`. The Image Publisher IAM trust policy uses branch-based OIDC subjects such as `repo:<owner>/<repo>:ref:refs/heads/main`; attaching a GitHub Environment to that job would change the OIDC subject and break the trust contract.

The release/PR job is a separate authority. It receives GitHub repository write permissions (`contents: write` and `pull-requests: write`) but no AWS credentials and no `id-token`. The repository must allow GitHub Actions to create pull requests if automatic release-PR creation is desired.

Workload Plan environments also require an explicit `ISOLATION_ALLOWED` value of exactly `true` or `false`. Select this value deliberately for each deployment; repository documentation is not evidence of the live GitHub Environment variable settings. The protected Apply job consumes the reviewed saved plan and does not re-resolve this input.

The Apply environment also requires `STATE_STACK_BACKEND_KEY` when workload-account reconciliation materializes the state-stack backend for strict post-apply validation.

Workload plan-producing jobs also read optional `MAIN_VPC_CIDR`, `RDS_INSTANCE_CLASS`, `ALB_CERTIFICATE_ARN`, and `ALB_INGRESS_CIDRS`. The workflow exports the supplied values to the corresponding Terraform inputs. Keep these consistent across normal Apply, standalone Plan, and Destroy; in particular, a custom-CIDR deployment must not be destroyed using a reconstructed default configuration. `ALB_INGRESS_CIDRS` is a JSON array, not a shell list. With no supplied CIDR override, the baseline default is `10.0.0.0/16`.

`STATE_STACK_BACKEND_KEY` is the state root's own key, distinct from the workload/account keys. Reconciliation materializes that backend using the **state template's region**, not `PRIMARY_REGION`. RC1 does not introduce a parallel GitHub `STATE_REGION` setting.

Secrets may include `ABUSEIPDB_API_KEY`. Keep all account IDs, role ARNs, region values, state settings, and deployment-profile choices aligned with the target environment. Do not publish secret input values or binary plans as public documentation evidence.

# Phase 10 - Deploy Environment Baseline

After setting necessary variables for the workload environments (see `environments/<env>/variables.tf`), deploy each environment from the `environments/<env>` directory.

> If using `GitHub OIDC`, be sure to add the `apply_role_github_arn` output value to each environment's `bucket_admin_principals` variable.

You can deploy through GitHub Actions once OIDC roles and GitHub environment variables are configured or you can deploy locally if not.

When the `Terraform Apply` workflow is used, it does not immediately run `terraform apply`. It first:

1. runs the Plan job through `<env>-plan` and the Plan role;
2. publishes the readable plan and uploads the saved plan artifact;
3. waits for approval on the protected `<env>` environment;
4. verifies the plan metadata and checksum; and
5. applies the exact saved plan through the Apply role.

The optional `reconcile_workload_account` input starts the plan-first reconciliation workflow after a successful baseline apply.

Normal production operation must keep `production_retirement_mode = false`. Intentional production teardown uses a separate staged retirement procedure before the Destroy workflow is allowed to remove the workload. Do not switch a production workload to a cheaper deployment profile in order to bypass lifecycle protection.

For the canonical production retirement procedure, see:

```text
docs/production-retirement.md
```

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
export AWS_REGION="$SERVICE_REGION"
export AWS_DEFAULT_REGION="$AWS_REGION"

terraform -chdir=environments/dev init
terraform -chdir=environments/dev plan
terraform -chdir=environments/dev apply
```

## Staging

```bash
export AWS_PROFILE=staging
export AWS_REGION="$SERVICE_REGION"
export AWS_DEFAULT_REGION="$AWS_REGION"

terraform -chdir=environments/staging init
terraform -chdir=environments/staging plan
terraform -chdir=environments/staging apply
```

## Prod

```bash
export AWS_PROFILE=prod
export AWS_REGION="$SERVICE_REGION"
export AWS_DEFAULT_REGION="$AWS_REGION"

terraform -chdir=environments/prod init
terraform -chdir=environments/prod plan
terraform -chdir=environments/prod apply
```

Record environment outputs needed by the `bootstrap/control_plane/identity_center` stack, such as:

```text
logs_s3_readonly_policy_name
logs_cmk_decrypt_policy_name
```

If using GitHub OIDC, the account reconciliation helper later reads `lambda_cmk_arn` and `secrets_manager_cmk_arn` directly from the workload Terraform state. Those CMK values do not need to be copied manually.

Also confirm the effective profile outputs:

```text
deployment_profile
egress_mode
effective_egress_mode
effective_cloudwatch_retention_days
effective_enable_config
effective_enable_rules
effective_backup_enabled
effective_backup_schedule
effective_delete_backups_after_days
effective_inspector_enabled
effective_manage_securityhub_cspm_locally
effective_manage_guardduty_locally
effective_manage_securityhub_v2_locally
ecs_cluster
guardduty_ecs_runtime_coverage_notification
primary_region
network_topology
rds_configuration
backup_vault_configuration
restore_testing
lifecycle_protection
```

These outputs confirm how profile defaults and explicit overrides resolved for the environment. In the centralized deployment, the three `effective_manage_*_locally` security-service outputs should be `false`.

### Optional ECS/Fargate Application Runtime

EC2 remains supported. For modern long-running SaaS services, use the canonical tracked workload configuration:

```text
environments/<env>/container-workloads.auto.tfvars.json
```

Operators maintain one `ecs_services` map. Baseline derives the narrower ECR, IAM, ALB, security-policy, and ECS-runtime inputs; do not create a second operator-maintained service inventory.

A service can be **registered but unreleased** by setting its digest to `null`:

```json
{
  "repositories": {},
  "ecs_services": {
    "api": {
      "repository_name": "api",
      "image_digest": null,
      "container_port": 8080,
      "cpu": 256,
      "memory": 512,
      "desired_count": 3
    }
  }
}
```

With `image_digest = null`, Terraform retains/creates the service-required ECR repository but does not create the per-service ECS runtime: no ECS service, task definition, per-service task/execution roles, task security group, application log group, Application Auto Scaling target/policy, or ECS operational alarm is materialized. This allows ECR to exist before the first application image is published without introducing a separate Terraform state or a second service map.

The shipped RC1 `test` entries are registered-but-unreleased with `image_digest=null`, including production. The production sample retains `desired_count=3` for a later release, but a fresh baseline apply does not start those tasks. Select an actual published digest through the reviewed application release path before claiming live ECS/ALB coverage.

### GuardDuty Fargate Runtime Monitoring

Runtime Monitoring is a cluster/runtime security capability; it does not add fields to the canonical `ecs_services` map.

Baseline derives the effective intent from `deployment_profile`:

```text
production  -> GuardDutyManaged=true
development -> GuardDutyManaged=true
minimal     -> GuardDutyManaged=false
```

For `production` and `development`, each deployable service's task execution role receives only the additional ECR image-pull scope required for the regional AWS-hosted `aws-guardduty-agent-fargate` repository. Existing application ECR scope remains separate and resource-scoped. `minimal` receives no GuardDuty-agent repository authority.

The private prerequisites remain Terraform-owned:

```text
ECS task SG
  +-- HTTPS -> ecr.api / ecr.dkr Interface Endpoints
  +-- HTTPS -> S3 prefix-list path through the S3 Gateway Endpoint
  +-- HTTPS -> guardduty-data Interface Endpoint
```

The Terraform task definition remains application-only. GuardDuty service-manages the runtime agent injected into protected tasks. Live ECS may report that container as `aws-gd-agent` or an AWS-generated `aws-guardduty-agent-<suffix>` name.

A new protected service deployment should receive Runtime Monitoring instrumentation once the centralized GuardDuty policy, task execution IAM, networking, and cluster tag are in place. Existing tasks are not silently retrofitted, so adopting Runtime Monitoring for an already-running service requires one deliberate new deployment. Terraform does not permanently force a deployment on every apply.

After deployment, `validate-ecs-runtime.sh` verifies the live cluster tag, injected agent, application container, and GuardDuty ECS coverage. Protected tasks must have valid running instrumentation, and the cluster’s GuardDuty coverage must report `AUTO_MANAGED`, `HEALTHY`, and no unresolved issues. For `minimal`, injected agents and healthy coverage are not required.

### Optional ECS scaling and deployment health

A deployable service remains fixed-count when `scaling` is omitted or `null`; Terraform owns `desired_count` exactly. To enable Application Auto Scaling, add a `scaling` object. The configured `desired_count` then becomes bootstrap capacity and must be within the configured min/max range; Application Auto Scaling owns subsequent live desired-count changes.

Example **development** scaling configuration. Replace the digest placeholder with an actual published 64-character lowercase hexadecimal digest. For production, use at least two for the fixed count or scaling minimum, with bootstrap capacity inside the bounds:

```json
{
  "repositories": {},
  "ecs_services": {
    "api": {
      "repository_name": "api",
      "image_digest": "sha256:<64-lowercase-hex-characters>",
      "container_port": 8080,
      "cpu": 256,
      "memory": 512,
      "desired_count": 1,
      "scaling": {
        "min_capacity": 1,
        "max_capacity": 2,
        "cpu_target_percent": 50,
        "memory_target_percent": 60,
        "scale_in_cooldown_seconds": 60,
        "scale_out_cooldown_seconds": 60
      },
      "deployment": {
        "minimum_healthy_percent": 100,
        "maximum_percent": 200,
        "health_check_grace_period_seconds": 120
      }
    }
  }
}
```

At least one target-tracking metric must be configured when `scaling` is non-null. CPU and memory targets may be used independently or together. `alb_requests_per_target` is also supported, but only for a service that configures `ingress`; its resource label is derived from Terraform-owned ALB/target-group identities. RC1 retains the target-tracking-only scaling contract introduced in v1.9.

Terraform-owned operational alarms are separate from AWS-managed target-tracking alarms. When Container Insights is enabled, each deployable service receives a task-deficit alarm. Each deployable ingress service receives an ALB unhealthy-target alarm. Both notify the SecOps SNS topic on ALARM and OK transitions.

The normal application release lifecycle is:

```text
registered ecs_services entry (image_digest = null or previous digest)
  -> Deploy Application
  -> resolve repository + platform from tracked canonical config
  -> build image
  -> push to ECR with the dedicated Image Publisher OIDC role
  -> resolve and re-check authoritative ECR sha256 digest
  -> release/PR job updates only ecs_services.<service>.image_digest
  -> automated release PR
  -> human review and merge
  -> run Terraform Apply separately
  -> internal Apply-workflow Plan creates the saved binary plan
  -> protected approval
  -> verify checksum/metadata and apply the exact reviewed plan
  -> ECS convergence
  -> workload validation/evidence
```

`Deploy Application` does **not** merge the release PR, invoke Terraform Apply, wait for ECS convergence, or run the workload evidence workflow. Those remain separate reviewed stages.

Terraform never builds or pushes application images. The deployed task definition uses only an immutable digest reference:

```text
<repository_url>@sha256:<digest>
```

The publisher job has AWS OIDC/ECR authority and only `contents: read`. The release/PR job has GitHub repository write authority but no AWS credentials or OIDC token. This keeps image publication authority separate from source-control mutation authority.

Build contexts supplied to `Deploy Application` must resolve inside the checkout. RC1 installs the Amazon ECR Docker credential helper in the publisher job. The publication script uses a temporary helper-only Docker configuration for the push, disables the helper’s token-file cache, and removes that temporary directory on normal exit/failure. It does not use `docker login`; this does not erase unrelated credentials already present in a local Docker configuration, and abrupt process/host termination is not guaranteed to execute cleanup.

Local publication requires `docker-credential-ecr-login` and an explicit `--region` or `AWS_REGION`; a named `--profile` is exported for helper use. See [deployment scripts](../scripts/deployment/README.md) for the supported inputs and boundaries. Publication success is not proof of ECS deployment.

For a deployable service, Fargate tasks run in compute-private subnets with `awsvpc`, no public IP, per-service task security groups, separate task execution/application task roles, deployment circuit breaking, and automatic rollback. Per-service application log groups use `/aws/ecs/<name-prefix>/<service>`. The cluster module owns `/aws/ecs/containerinsights/<cluster-name>/performance` when Container Insights is enabled; both log types use the effective CloudWatch retention policy and workload logs CMK where applicable.

When ingress is configured, also provide `alb_certificate_arn` and at least one `alb_ingress_cidrs` value. Each deployable ingress service supplies a unique listener-rule priority and at least one host-header or path-pattern condition. The shared ALB’s client listener is HTTPS-only and defaults to `ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09` unless overridden. Its target groups and health checks use **HTTP** to tasks; this is not end-to-end TLS. The certificate must be in `primary_region`, and baseline supplies the exact ingress-public subnet set.

# Phase 11 - Reconcile Environment Account Stacks (Skip if not using `GitHub OIDC`)

After successfully applying each environment baseline, reconcile the current workload-created Lambda and Secrets Manager CMK permissions into `bootstrap/<env>/account`.

## GitHub Actions

The `Reconcile Workload Account` workflow supports:

```text
plan-only
plan-and-apply
```

`plan-only` generates the reconciliation plan, publishes the readable output, and uploads the saved plan artifact without starting an Apply job.

`plan-and-apply` generates the plan first, then pauses on the protected `dev`, `staging`, or `prod` environment. After approval, the Apply job downloads and verifies the exact saved plan, applies it through the GitHub Apply role, and runs strict workload bootstrap validation.

The plan is generated through the matching `*-plan` environment. Both the Plan and Apply environments must contain the same generic `ACCOUNT_ID` for the target AWS account.

The `Terraform Apply` workflow can invoke `plan-and-apply` automatically when its `reconcile_workload_account` input is selected.

## Local Execution

The helper uses Terraform's normal variable-loading behavior for the account stack, including `terraform.tfvars`, `*.auto.tfvars`, exported `TF_VAR_*` variables, defaults, and optional `--var` or `--var-file` arguments. It overrides only `lambda_cmk_arn` and `secrets_manager_cmk_arn` with the current workload outputs.

For an exact plan review across two local invocations, save the plan explicitly with `--plan-file`, then apply that same file with `--apply-plan`. `AWS_REGION` is required and must match the planned service `primary_region`; it need not match the separately resolved state backend region.

Preserve the account’s existing role enablement and branch inputs, especially `enable_image_publisher_role_github` and `branches_image_publisher_github`. The GitHub reconciliation workflow supplies publisher settings explicitly; a local run uses the actual local Terraform inputs. It must not accidentally disable the publisher role. The strict bootstrap validator checks publisher trust and ECR policy when the role is present; the old manual-only limitation no longer applies.

### Dev

```bash
umask 077
DEV_RECONCILIATION_DIR="$(mktemp -d)"
DEV_RECONCILIATION_PLAN="${DEV_RECONCILIATION_DIR}/account-reconciliation.tfplan"

AWS_PROFILE=dev \
AWS_REGION="${SERVICE_REGION}" \
EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
./scripts/bootstrap/reconcile-workload-account.sh dev \
  --plan-file="${DEV_RECONCILIATION_PLAN}"

AWS_PROFILE=dev \
AWS_REGION="${SERVICE_REGION}" \
EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
./scripts/bootstrap/reconcile-workload-account.sh dev \
  --apply-plan="${DEV_RECONCILIATION_PLAN}"
```

### Staging

```bash
umask 077
STAGING_RECONCILIATION_DIR="$(mktemp -d)"
STAGING_RECONCILIATION_PLAN="${STAGING_RECONCILIATION_DIR}/account-reconciliation.tfplan"

AWS_PROFILE=staging \
AWS_REGION="${SERVICE_REGION}" \
EXPECTED_ACCOUNT_ID="<STAGING-ACCOUNT-ID>" \
./scripts/bootstrap/reconcile-workload-account.sh staging \
  --plan-file="${STAGING_RECONCILIATION_PLAN}"

AWS_PROFILE=staging \
AWS_REGION="${SERVICE_REGION}" \
EXPECTED_ACCOUNT_ID="<STAGING-ACCOUNT-ID>" \
./scripts/bootstrap/reconcile-workload-account.sh staging \
  --apply-plan="${STAGING_RECONCILIATION_PLAN}"
```

### Prod

```bash
umask 077
PROD_RECONCILIATION_DIR="$(mktemp -d)"
PROD_RECONCILIATION_PLAN="${PROD_RECONCILIATION_DIR}/account-reconciliation.tfplan"

AWS_PROFILE=prod \
AWS_REGION="${SERVICE_REGION}" \
EXPECTED_ACCOUNT_ID="<PROD-ACCOUNT-ID>" \
./scripts/bootstrap/reconcile-workload-account.sh prod \
  --plan-file="${PROD_RECONCILIATION_PLAN}"

AWS_PROFILE=prod \
AWS_REGION="${SERVICE_REGION}" \
EXPECTED_ACCOUNT_ID="<PROD-ACCOUNT-ID>" \
./scripts/bootstrap/reconcile-workload-account.sh prod \
  --apply-plan="${PROD_RECONCILIATION_PLAN}"
```

The simpler `--apply` mode remains available. It generates a plan, displays it, asks for confirmation, and applies that plan within the same invocation. A separate earlier plan-only run is not reused unless `--plan-file` and `--apply-plan` are used.

Use `--var-file <path>` when account inputs are stored in a custom variable file that Terraform would not auto-load. Relative paths are resolved from the selected `bootstrap/<env>/account` directory. Do not combine `--apply-plan` with `--var` or `--var-file`; the reviewed saved plan already contains the resolved input values.

Saved Terraform plan files may contain sensitive configuration values. Store local plan files securely and remove them after the apply and validation complete.

---

# Phase 12 - Deploy IAM Identity Center

The Identity Center stack is deployed from the control plane and manages workforce access to both workload accounts and the centralized security-operations account.

It uses two consolidated Terraform inputs:

```text
identity_center_workloads
identity_center_secops
```

The workload map contains `dev`, `staging`, and `prod`. Each workload always receives its `SecOps-Operator` access model; optional Analyst and Engineer access remains disabled unless explicitly enabled. The security-operations object always enables the required `SecOps-Administrator` access model, while its Analyst and Engineer roles are optional.

For GitHub Actions, the matching control-plane environment variables are:

```text
IDENTITY_CENTER_WORKLOADS
IDENTITY_CENTER_SECOPS
```

For local deployment, create `bootstrap/control_plane/identity_center/terraform.tfvars` from its example only when no local file already exists. Populate the workload account IDs, Regions, expected workload policy names, and security-operations account ID. Review rather than overwrite an existing configuration.

Then apply:

```bash
export AWS_PROFILE=control-plane
export AWS_REGION="$SERVICE_REGION"
export AWS_DEFAULT_REGION="$AWS_REGION"

terraform -chdir=bootstrap/control_plane/identity_center init
terraform -chdir=bootstrap/control_plane/identity_center plan
terraform -chdir=bootstrap/control_plane/identity_center apply
```

Required groups include:

```text
SecOps-Operator-Dev
SecOps-Operator-Staging
SecOps-Operator-Prod
SecOps-Administrator
```

Workload-created customer-managed policy names are only attached when the corresponding optional Analyst or Engineer role is enabled. Keeping those roles disabled during the first deployment avoids a circular dependency; re-apply Identity Center after workload deployment if optional access is later enabled.

---

# Phase 13 - Validate Deployment

After deployment completes, run the validation checklist:

```text
docs/validation-checklist.md
```

For release or client-readiness evidence, use `REQUIRE_STATE_STACK_REMOTE=true` for direct bootstrap and control-plane validation. The GitHub evidence workflows set this requirement to `true` by default.

Recommended validation order:

1. Verify every migrated state stack:
   ```bash
   AWS_PROFILE=control-plane AWS_REGION="${STATE_REGION}" ./scripts/bootstrap/migrate-state-stack.sh control-plane --verify-only
   AWS_PROFILE=security-operations AWS_REGION="${STATE_REGION}" ./scripts/bootstrap/migrate-state-stack.sh security-operations --verify-only
   AWS_PROFILE=dev AWS_REGION="${STATE_REGION}" ./scripts/bootstrap/migrate-state-stack.sh dev --verify-only
   AWS_PROFILE=staging AWS_REGION="${STATE_REGION}" ./scripts/bootstrap/migrate-state-stack.sh staging --verify-only
   AWS_PROFILE=prod AWS_REGION="${STATE_REGION}" ./scripts/bootstrap/migrate-state-stack.sh prod --verify-only
   ```
2. Run the **Export Control Plane Evidence** workflow and confirm Organizations topology, account placement, delegated-administrator prerequisites, and Identity Center are green.
3. Run the **Export Security Operations Evidence** workflow and confirm Security Hub CSPM, Security Hub V2, and the centralized GuardDuty contract are green, including `RUNTIME_MONITORING = ALL`, `ECS_FARGATE_AGENT_MANAGEMENT = ALL`, `EC2_AGENT_MANAGEMENT = ALL`, and `EKS_ADDON_MANAGEMENT = NONE`.
4. Run **Export Bootstrap Evidence** and **Export Baseline Evidence** for each workload environment.
5. Confirm GitHub OIDC roles can be assumed by the applicable workflows.
6. Confirm deployment profile outputs resolved correctly, including nullable Backup schedule/retention and the ECS cluster Runtime Monitoring intent.
7. Confirm egress mode behavior:
   - `network_firewall`: Network Firewall and NAT Gateway are deployed, compute private default route points to firewall endpoints.
   - `nat_only`: Network Firewall is not deployed, NAT Gateway is deployed, compute private default route points to NAT.
   - `vpc_endpoints_only`: Network Firewall and NAT Gateway are not deployed, compute private subnets have no default route.
8. Confirm dedicated endpoint private subnets exist.
9. Confirm all Terraform-managed Interface VPC Endpoints, including `guardduty-data`, are deployed into endpoint private subnets.
10. Confirm the live Interface Endpoint IDs exactly match Terraform output and exactly one `guardduty-data` endpoint exists; Runtime Monitoring must reuse it rather than introduce a duplicate endpoint/security group.
11. Confirm the S3 Gateway Endpoint is associated with the expected private route tables.
12. Confirm workload-local AWS Config and Inspector are active where expected by profile, and confirm the exact enabled/disabled AWS Backup contract with `validate-backup.sh`.
13. Confirm centralized Security Hub CSPM policy associations and effective Security Hub V2 workload policies are healthy after workload deployment.
14. Run the full 16-validator workload baseline suite, including `validate-ecr.sh`, `validate-ecs-runtime.sh`, `validate-eventbridge.sh`, and the ECS-aware `validate-iam.sh`; empty repository/service maps are valid and the environment cluster is still checked.
15. For protected `production`/`development` ECS services, confirm `GuardDutyManaged=true`, exactly one injected GuardDuty agent is `RUNNING`, the application remains valid, GuardDuty coverage is `AUTO_MANAGED` and `HEALTHY` with no unresolved issues, exact agent ECR authority is present, and the coverage-state EventBridge notification path matches Terraform. For `minimal`, confirm `GuardDutyManaged=false`, no agent ECR authority, and valid disabled-state coverage semantics.
16. When ECS services are configured, also confirm steady state with digest-pinned images, private task networking, exact logging encryption, declared database/ALB relationships, fixed-versus-autoscaled desired-count ownership, exact scaling/deployment settings, and expected ECS operational alarms.
17. Confirm SNS subscriptions are confirmed.
18. Run separately approved Lambda behavioral tests in an appropriate test context; they are not the read-only validation suite:
    - `docs/lambda_tests/ec2_isolation.md`
    - `docs/lambda_tests/ec2_rollback.md`
    - `docs/lambda_tests/ip_enrichment.md`

---

## Evidence and release qualification boundaries

Keep the four validation/evidence layers separate: control plane, centralized security operations, workload bootstrap, and workload baseline. A `16/16` workload pass does not prove the other three layers passed, nor that every possible RDS attribute or application behavior was checked.

For production, retain the effective input set, implementation SHA, profile, region/CIDR/AZ topology, selected image digest, live task placement, target health, validator logs, and no-change plan. The shipped null digest is intentionally different from the digest-selected service used in application qualification.

`validate-backup.sh` can pass with warnings when a fresh environment has no restore-test jobs or no current recovery points. Treat restore configuration, actual restore execution, temporary-resource cleanup, and application-data correctness as different claims. Earlier R8 failover/restore/task-replacement evidence must keep its original provenance; do not relabel it as an exact-RC1 test.

A final normal-operation no-change plan should use the same effective configuration as the deployment. It does not replace separately approved retirement/destroy qualification. Do not run destructive or fault-injection tests merely because an account-wide informational command completed.

## Deployment Order Summary

```text
1. Bootstrap control-plane state
2. Deploy control-plane account and Organizations stacks
3. Bootstrap security-operations state and account stacks
4. Deploy security-operations/security_services
5. Bootstrap workload state and account stacks
6. Deploy workload environments
7. Reconcile workload account stacks when GitHub OIDC is enabled
8. Deploy or re-apply control-plane Identity Center
9. Run control-plane, security-operations, bootstrap, and baseline evidence workflows
```

Architecturally:

```text
control-plane -> security-operations -> bootstrap-workloads -> workloads
```

---

## GitHub Actions

After GitHub OIDC roles and environment variables are configured, CI/CD can manage normal plan/apply/destroy operations.

Expected workflows:

| Workflow | Purpose |
|---------|---------|
| Terraform Static Analysis | Runs static Terraform validation and scanning |
| Docs Validation | Runs documentation linting and link checks |
| Terraform Plan | Runs independent informational/review plans for workload, selected control-plane, and security-operations security-services stacks; this plan is not consumed by Terraform Apply |
| Terraform Apply | Generates its own saved binary workload plan, readable plan, metadata, and checksum; waits for protected-environment approval; verifies and applies that exact plan without replanning |
| Deploy Application | Builds/publishes an application image with the dedicated Image Publisher role, resolves the authoritative digest, and creates a one-field release PR; it does not run Terraform Apply |
| Reconcile Workload Account | Runs `plan-only` or generates a reconciliation plan, waits for approval, applies the exact saved plan, and runs strict bootstrap validation |
| Terraform Destroy | Runs preflight; production adds separately approved durable cleanup/readiness; then workload destroy planning, separate Identity Center cleanup plan/apply, and final approved exact destroy apply |
| Export Bootstrap Evidence | Materializes the state backend, initializes workload roots, and exports bootstrap evidence |
| Export Baseline Evidence | Exports the 16-script workload baseline evidence package |
| Export Control Plane Evidence | Materializes the control-plane state backend, initializes control-plane roots, and exports control-plane evidence |
| Export Security Operations Evidence | Validates centralized Security Hub CSPM, GuardDuty, and Security Hub V2 governance from `security-operations-plan` |

The standalone `Terraform Plan` workflow remains useful for pull requests, pushes, and independent review. `Terraform Apply` generates its own plan in the same workflow run so the protected Apply job can consume the exact artifact that was presented for approval.

Workload Plan jobs use `dev-plan`, `staging-plan`, or `prod-plan`; Apply jobs use the matching protected `dev`, `staging`, or `prod` environment. The standalone Plan workflow also uses `control-plane-plan` and `security-operations-plan` for their supported stacks. Configure `ACCOUNT_ID` in both members of each pair and configure `ISOLATION_ALLOWED` in the workload Plan environment. The workflows validate the role ARN account, the active AWS caller account, the expected account stored in saved-plan metadata, and the isolation value before planning.

Saved binary plans are short-lived artifacts because Terraform plans can contain sensitive values. Keep repository and workflow-run access limited to trusted operators.

The Destroy workflow follows the same reviewed-plan principle as Apply: it generates a readable saved destroy plan, records metadata/checksum evidence, pauses on the protected environment, verifies the exact artifact after approval, and applies that exact destroy plan without replanning.

For `prod` with `deployment_profile=production`, Destroy first requires converged Stage-1 retirement and explicit `delete_durable_retirement_data=true`. It inventories durable data, obtains the protected cleanup approval, deletes the scoped ECR images/Backup recovery points, and verifies readiness before producing the workload destroy plan.

The subsequent dependency order is:

```text
saved workload destroy plan
  -> Identity Center cleanup plan
  -> control-plane approval and exact cleanup apply
  -> workload destroy approval
  -> artifact verification and production readiness recheck
  -> exact workload destroy apply
```

The Identity Center approval is separate from the final workload approval. A later rejection does not undo earlier access changes or durable-data deletion. Cleanup applies a fresh inventory; it does not replay the preflight item list as a checksummed deletion artifact. The [retirement runbook](production-retirement.md) describes the complete boundaries and abort behavior.

Development/minimal teardown sets `delete_durable_retirement_data=false` and does not require production retirement mode, but the workflow still includes the Identity Center cleanup dependency.

Evidence jobs use Plan-role credentials and read-only validation commands. That description does not imply the IAM role has no write permissions whatsoever: Terraform planning/backend operations have their own state/lock permissions. On clean runners the relevant state/backend files must be materialized before initialization; bootstrap/control-plane evidence requires remote-state proof by default.

---

## Important Notes

### State Stacks Use a Two-Phase Bootstrap Lifecycle

The first state-stack apply is local because the S3 backend does not exist yet.

After that initial apply, run:

```bash
AWS_REGION="$STATE_REGION" ./scripts/bootstrap/migrate-state-stack.sh dev
# Other supported targets: staging, prod, control-plane, security-operations.
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

Workloads reach Interface Endpoints over VPC-local routing and security group rules. The Terraform-managed endpoint set includes `guardduty-data`. Compute waits for Interface Endpoint creation before EC2 launches, while each deployable ECS task security group receives HTTPS access to the shared Interface Endpoint security group and S3 prefix-list path. GuardDuty Runtime Monitoring therefore reuses the same Terraform-owned endpoint tier for eligible EC2 and ECS/Fargate workloads.

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
- GuardDuty, including Runtime Monitoring monitored-vCPU/runtime-agent overhead for protected ECS/Fargate workloads
- Security Hub
- Inspector
- KMS requests
- RDS instance capacity, including production Multi-AZ and temporary Restore Testing databases
- Backup storage
- ECS/Fargate runtime capacity and Application Load Balancers when services are deployed

Deployment profiles and egress modes can reduce cost for non-production environments, but they also change security and connectivity behavior.

Review estimated costs before deploying all environments.

---

## Summary

This quickstart deploys `tf-secure-baseline` in the intended order:

- Bootstrap control-plane foundations
- Bootstrap and configure the centralized security-operations layer
- Bootstrap workload backends and GitHub OIDC roles
- Deploy workload baselines
- Confirm deployment profile and egress mode behavior
- Deploy centralized Identity Center access
- Validate each architecture layer through its evidence workflow

After completion, the platform provides a multi-account AWS security baseline with centralized identity, delegated security administration, secure CI/CD, logging, profile-driven GuardDuty ECS/Fargate Runtime Monitoring, configurable egress behavior, private VPC endpoint access, and event-driven response automation.

# Destruction / Cleanup Procedure

Workload retirement, optional account-role removal, and administrative state/platform decommissioning are different operations. Do not treat one successful workload destroy as permission or proof that the entire platform can be removed safely.

Destroying stacks out of order can leave IAM dependencies, remove the GitHub roles needed for cleanup, or orphan active state. Preserve required application data, images, audit logs, recovery artifacts, keys, and external state backups before authorizing deletion.

A state root must never destroy the S3 bucket holding its own active state. Moving that state to an independent backend is necessary but **not sufficient**: [modules/state](../modules/state/README.md) has literal `prevent_destroy=true` on both its bucket and CMK. Workload `production_retirement_mode` does not disable those guards.

---

## Workload Environment Destruction

### Development and minimal profiles

Use the reviewed `Terraform Destroy` workflow with the intended environment, `confirm=DESTROY`, and `delete_durable_retirement_data=false`. Keep the exact deployed inputs, including a non-default `MAIN_VPC_CIDR`, aligned with the plan path.

Local teardown is a separate operator-controlled path. Resolve the intended AWS caller and Terraform root, remove only the relevant optional Identity Center policy dependencies, and review the full destroy plan before approving. A conceptual local command after those prerequisites is:

```bash
ENV_NAME="dev"  # Substitute the reviewed development/minimal target.
AWS_PROFILE="$ENV_NAME" AWS_REGION="$SERVICE_REGION" \
  terraform -chdir="environments/${ENV_NAME}" destroy
```

This command is not a substitute for the protected GitHub workflow or production retirement. Do not remove the workload account/OIDC stack first.

### Production profile

The complete RC1 automated retirement path supports **`prod`**. Its order is:

```text
normal production (production_retirement_mode=false)
  -> Terraform Apply with production_retirement_mode=true
  -> exact Stage-1 plan and non-destructive plan guard
  -> protected approval and exact Stage-1 apply
  -> read-only durable-data inventory
  -> Terraform Destroy preflight and convergence check
  -> separately approved durable cleanup
  -> readiness validation
  -> saved workload destroy plan
  -> separately planned/approved Identity Center cleanup
  -> final workload-destroy approval
  -> artifact verification and readiness recheck
  -> exact saved destroy-plan apply
```

Use [docs/production-retirement.md](production-retirement.md) as the canonical runbook. It documents the separate approval points and current helper scope.

Stage 1 derives service capacity zero while keeping the canonical image selection and service definition. It relaxes the native RDS/ALB/Network Firewall deletion protections but keeps ECR/ECS force deletion and Backup vault force destruction disabled. RDS final snapshots and automated-backup retention remain required.

The production Destroy request requires:

```text
environment                    = prod
confirm                        = DESTROY
delete_durable_retirement_data = true
```

That explicit cleanup authorization is required even when the scoped repositories/vault are already empty. The cleanup helper permanently deletes the current scoped inventory; it does not archive assets for you. Decide retention and perform separately approved preservation first.

Do not change the deployment profile, delete the service entry, or set its digest to `null` merely to bypass retirement. Do not claim the cleanup is covered by the later Terraform destroy-plan approval. Rejecting a later job does not restore assets already deleted by an earlier approved job.

---

## Identity Center Dependency

For one workload, do not destroy the whole Identity Center stack. Optional Analyst/Engineer access can depend on workload-created IAM policies.

The workflow derives cleanup inputs by setting these fields to `false` for the selected workload inside `identity_center_workloads`:

```text
enable_secops_analyst
enable_secops_engineer
```

It plans and applies that control-plane change under its own approval **before the final workload-destroy approval**. Review the complete cleanup plan for unrelated changes; it is still a plan of the shared Identity Center root.

These effective input changes do not persistently rewrite the `IDENTITY_CENTER_WORKLOADS` GitHub variable or local configuration. Reconcile the intended long-term settings so a later Identity Center apply does not unexpectedly recreate dependencies on retired workload policies.

Keep the Identity Center stack and its backend available until all GitHub workload-destroy workflows that depend on it have completed. Do not follow a “destroy Identity Center first, then run the normal workload Destroy workflows” recipe.

---

## Workload Account and State Teardown

After a workload has been destroyed and all uses of its OIDC roles have ended, review the account-stack removal separately. Do not delete those roles while a workflow still needs them.

Before any state-root decommissioning, retain a private external state backup. For example, from the correct account context:

```bash
ENV_NAME="dev"  # Substitute the reviewed target.
STATE_DIR="bootstrap/${ENV_NAME}/state"
umask 077
STATE_BACKUP_DIR="$(mktemp -d "${HOME}/tf-state-backup.XXXXXX")"
terraform -chdir="$STATE_DIR" state pull > "$STATE_BACKUP_DIR/state.json"
test -s "$STATE_BACKUP_DIR/state.json"
printf 'Private state backup: %s\n' "$STATE_BACKUP_DIR"
```

This is **only a backup**, not an instruction to migrate or destroy the backend. It can contain sensitive information; retain it under the approved access/retention policy.

An approved state teardown must independently establish that dependent roots are handled, active state has moved off the bucket, the independent state is verified, the literal Terraform guards and AWS policy/versioned-object constraints are deliberately addressed, and retained data/keys remain recoverable. RC1 has no generic “retire state” toggle or reverse-migration/decommissioning helper that automates that whole process. See the relevant state-root README and [state module reference](../modules/state/README.md).

---

## Full Platform Teardown

This is a dependency checklist, **not** a fully qualified one-command platform destruction procedure. Workload lifecycle qualification does not establish that Organization, delegated-administrator, Identity Center, account-role, and state-resource teardown has been exercised as one complete platform operation.

### 0. Prepare Identity Center

Review the selected workload’s optional policy dependencies, but keep the shared Identity Center stack available for the normal Destroy workflow’s cleanup plan/apply. Complete those workload workflows before considering whole-stack removal.

### 1. Dev

Complete reviewed workload destruction, then separately assess whether its account roles or state backend should be retained. Do not remove a backend still used by another root.

### 2. Staging

Apply the same dependency rule. A production-profile staging environment does not gain a supported prod-only durable-cleanup workflow simply by selecting that profile; establish a separate approved path rather than bypassing the restriction.

### 3. Prod

Complete the [production retirement runbook](production-retirement.md), including explicit durable-data disposition. Retained RDS recovery artifacts, audit logs, state backups, and encryption/access dependencies need separate post-destroy review.

### 4. Security Operations

Retiring centralized security governance is not part of workload destroy. Review organization/delegated-administrator dependencies and workforce access before planning changes to `security_services`, then its account roles and state backend.

### 5. Control Plane

Keep shared identity and governance available while dependent operations require them. The Organization resource itself has `prevent_destroy=true`; a routine `terraform destroy` is not an implemented Organization-retirement procedure. State bucket and CMK guards remain separate. Plan any final decommissioning as an explicitly approved administrative operation, not as an automatic extension of v1.11 workload retirement.

---

## Important Destruction Notes

- Keep workload OIDC roles until the workload workflows are finished; keep backend resources until every dependent root and active state has been handled.
- Do not remove the whole Identity Center stack before workflows that still plan/apply its environment-specific cleanup.
- Preserve state externally before backend changes. Moving state does not relax the state module’s literal guards or empty a versioned bucket.
- Production native deletion protection, provider force-deletion flags, and explicitly approved data cleanup are separate mechanisms.
- The logs bucket’s `force_destroy=true` and disabled Object Lock are separate storage limits; the ECR/Backup cleanup helper is not an audit-log preservation service.
- A failed or cancelled later approval does not undo earlier approved cleanup. Inspect current state and re-plan through the reviewed path rather than applying stale artifacts.

## Source and Further Reading

- [Baseline defaults](../baseline/locals.tf) and [canonical validation](../baseline/variables.tf)
- [Workload example inputs](../environments/prod/variables.tf) and [toolchain constraints](../environments/prod/providers.tf)
- [GitHub OIDC trust](../modules/github_oidc/main.tf)
- [Terraform Apply](../.github/workflows/terraform-apply.yml) and [Terraform Destroy](../.github/workflows/terraform-destroy.yml)
- [Bootstrap scripts](../scripts/bootstrap/README.md) and [deployment scripts](../scripts/deployment/README.md)
- [State module](../modules/state/README.md), [storage module](../modules/storage/README.md), and [Backup](../modules/backup/README.md)
