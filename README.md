# terraform-secure-baseline

Opinionated Terraform baseline for deploying secure, cost-efficient AWS environments for early-to-mid-stage SaaS businesses handling customer data.

## NOTICE: PROPRIETARY CODE

This repository is the property of *NanoNexus Consulting*.

This code is made publicly viewable for demonstration purposes only.
No license is granted to use, copy, modify, or distribute this code
without explicit written permission.

---

## Overview

`tf-secure-baseline` is a Terraform-driven AWS security baseline designed for organizations running applications that handle PII or other sensitive data.

**Current published release:** `v1.5.0` — released July 18, 2026. The `v1.5.0` tag is immutable; changes merged afterward remain unreleased until a later version is tagged.

It provides a secure, multi-account cloud foundation with:

- Centralized identity and access management
- Secure-by-default networking
- Configurable deployment profiles
- Configurable egress modes
- Centralized logging, monitoring, and alert routing
- Automated detection and response
- Durable SNS/SQS notification paths with DLQs for failed alert delivery
- GitHub OIDC-based plan-before-approval CI/CD
- Exact reviewed-plan application through protected Apply environments
- Environment isolation across `dev`, `staging`, and `prod`
- SOC 2 / ISO 27001-aligned security architecture to support audit readiness

This project is intended for SaaS companies, startups, and engineering teams that need a repeatable AWS security foundation without building every security control from scratch.

> This baseline supports SOC 2 and ISO 27001 readiness, but it does not replace an organization’s full compliance program, ISMS, policies, risk management process, or formal audit requirements.

---

## What This Project Provides

This repository deploys a production-aligned AWS security baseline using Terraform.

Key capabilities include:

- Multi-account AWS architecture
- Centralized control plane
- IAM Identity Center access management
- GitHub Actions OIDC federation
- Private-first networking
- Configurable deployment profiles for production, development, and minimal deployments
- Configurable egress modes for Network Firewall, NAT-only, or VPC-endpoints-only operation
- AWS Network Firewall egress inspection when enabled
- Dedicated private subnets for Interface VPC Endpoints
- Private AWS service access through VPC endpoints
- Centralized CloudTrail, Config, and VPC Flow Logs
- GuardDuty, Security Hub, Inspector, and AWS Config
- Event-driven security automation
- Fail-closed EC2 isolation and controlled rollback workflows
- Terraform-managed Lambda deployment packaging
- IP threat enrichment
- Tamper detection
- Break-glass role monitoring
- SQS-backed security and compliance notification queues
- EventBridge target DLQs and workflow-specific automation DLQs
- Encrypted S3, KMS, SNS, SQS, CloudWatch, and Lambda resources
- First-boot Ubuntu package updates and scheduled SSM patching
- Dependency-aware EC2 launch ordering so required security group rules exist before user data runs
- Safe, read-only post-deployment validation suite
- Layer-specific validation evidence export with Markdown and JSON summaries

---

## Target Use Case

This baseline is designed for:

- SaaS companies handling PII
- Teams preparing for SOC 2 or ISO 27001
- Organizations that need secure AWS account separation
- Cloud security teams building reusable landing-zone patterns
- Startups that need production-ready security architecture early
- Consultants implementing secure AWS foundations for clients

---

## High-Level Architecture

```text
Manual-First State Bootstrap
    |
    v
Create S3 State Bucket and State CMK
    |
    v
scripts/bootstrap/migrate-state-stack.sh
    |
    v
Remote S3 State with Native Lockfiles
    |
    +--> bootstrap/control_plane/state
    +--> bootstrap/dev/state
    +--> bootstrap/staging/state
    +--> bootstrap/prod/state

Bootstrap and Governance Stacks
    |
    +--> bootstrap/control_plane/account
    +--> bootstrap/control_plane/organizations
    +--> bootstrap/control_plane/identity_center
    |
    +--> bootstrap/dev/account
    +--> bootstrap/staging/account
    +--> bootstrap/prod/account

GitHub Actions through OIDC
    |
    +--> <env>-plan / GitHub Plan role
    |       |
    |       +--> readable plan evidence
    |       +--> saved binary plan + metadata + checksum
    |
    +--> protected <env> / GitHub Apply role
            |
            +--> verify and apply exact reviewed plan
            +--> optional workload-account reconciliation
            +--> strict validation and evidence

Workload Environments
    |
    +--> environments/dev
    +--> environments/staging
    +--> environments/prod
```

Each `state` stack is initialized and applied locally first because it creates the S3 bucket and KMS key that will store its own Terraform state. After those resources exist, `scripts/bootstrap/migrate-state-stack.sh` materializes the ignored active `backend.tf` from the tracked `backend.tf.migrated.example`, migrates the existing local state into S3, and verifies that the remote state is readable.

The active `backend.tf` files for state stacks are intentionally ignored by Git. The tracked `backend.tf.migrated.example` files represent the post-migration backend configuration used by operators and GitHub evidence workflows.

Initial account and governance stacks remain manual-first. After the GitHub OIDC roles exist, GitHub Actions can plan and apply supported workload environment stacks. The Terraform Destroy workflow uses the control-plane apply role first to clean up Identity Center policy attachments, then uses the selected workload environment apply role to destroy that environment.

The platform separates the control plane from the workload environments.

The **control plane** manages:

- Control-plane Terraform backend infrastructure
- Control-plane GitHub OIDC execution roles
- AWS Organizations structure
- IAM Identity Center access

The **environment** stacks manage:

- Networking
- Deployment profile and egress mode behavior
- Logging
- Monitoring
- Security services
- Automation
- Compute
- Storage
- Backup
- Patch management

## Repository Structure

```text
.
├── bootstrap
│   ├── control_plane
│   │   ├── account
│   │   ├── identity_center
│   │   ├── organizations
│   │   └── state
│   ├── dev
│   │   ├── account
│   │   └── state
│   ├── staging
│   │   ├── account
│   │   └── state
│   └── prod
│       ├── account
│       └── state
│
├── environments
│   ├── dev
│   ├── staging
│   └── prod
│
├── modules
│   ├── automation
│   │   └── lambda
│   ├── backup
│   ├── compute
│   │   └── user_data
│   ├── firewall
│   ├── github_oidc
│   ├── iam
│   ├── identity_center
│   ├── logging
│   ├── monitoring
│   ├── networking
│   │   └── security_policy
│   ├── patch_management
│   ├── security
│   │   ├── config_baseline
│   │   └── tamper_detection
│   ├── security_dashboard
│   ├── state
│   ├── storage
│   └── vpc_endpoints
│
├── docs
│   ├── architecture-overview.md
│   ├── design-principles.md
│   ├── quickstart.md
│   ├── adoption-guide.md
│   ├── validation-checklist.md
│   ├── assurance
│   └── lambda_tests
│
├── scripts
│   ├── bootstrap
│   │   ├── lib
│   │   │   └── common.sh
│   │   ├── migrate-state-stack.sh
│   │   ├── reconcile-workload-account.sh
│   │   └── README.md
│   └── validation
│       ├── lib
│       │   └── common.sh
│       ├── export-baseline.sh
│       ├── export-bootstrap.sh
│       ├── export-control-plane.sh
│       ├── validate-backup.sh
│       ├── validate-baseline.sh
│       ├── validate-bootstrap.sh
│       ├── validate-control-plane.sh
│       ├── validate-compute.sh
│       ├── validate-env.sh
│       ├── validate-eventbridge.sh
│       ├── validate-iam.sh
│       ├── validate-kms.sh
│       ├── validate-lambda.sh
│       ├── validate-logging.sh
│       ├── validate-networking.sh
│       ├── validate-security-services.sh
│       ├── validate-sns.sh
│       ├── validate-sqs.sh
│       ├── validate-ssm.sh
│       └── validate-vpc-endpoints.sh
│
├── .github
│   └── workflows
│
├── CHANGELOG.md
├── README.md
└── SECURITY.md
```

## Terraform Variable Templates

Terraform roots that require local configuration include a tracked `terraform.tfvars.example` template. Terraform does not automatically load files ending in `.example`, so copy the applicable template before running Terraform locally:

```bash
cp environments/dev/terraform.tfvars.example \
  environments/dev/terraform.tfvars
```

Review the copied file and replace example values with the correct deployment-specific configuration. Runtime `terraform.tfvars` files are ignored by Git and must not be committed. GitHub Actions receives its deployment values separately through workflow matrices, GitHub variables, and GitHub secrets rather than loading the example files.

## Core Design Principles

### Private-First Infrastructure

Compute workloads are deployed in private subnets by default.

The baseline avoids public IPs for application infrastructure and routes private compute egress through controlled paths, including AWS Network Firewall, NAT Gateway, and VPC endpoints where appropriate.

### Dependency-Safe First Boot

The compute security group is created before the networking security-policy rules that reference it. The security-policy module exports the required compute rule IDs through the networking module, and the compute module uses those IDs as a `terraform_data` readiness checkpoint.

Only the EC2 instances wait on that checkpoint. This avoids a cyclic module dependency while ensuring first-boot user data does not run before required endpoint, database, and conditional internet HTTPS rules exist.

### Configurable Cost/Security Profiles

The baseline supports deployment profiles that select sensible defaults for each environment type.

Profiles allow teams to run a full production-style architecture where needed while using lower-cost defaults for development or minimal testing environments.

### Multi-Account Isolation

The platform separates environments into dedicated AWS accounts:

```text
dev
staging
prod
bootstrap / control-plane
```

This improves blast-radius reduction, access control, and operational isolation.

### Control Plane Separation

The control plane is isolated from workload infrastructure.

This prevents Terraform from destroying or modifying the execution roles, state resources, and identity infrastructure it depends on.

### No Long-Lived CI/CD Credentials

GitHub Actions authenticates to AWS using OIDC.

No static AWS access keys are required for CI/CD workflows.

### Centralized Identity

IAM Identity Center is used for human access.

Permission sets and account assignments are managed centrally from the control plane.

### Event-Driven Security Automation

Security events are routed through EventBridge and trigger automated workflows such as:

- EC2 isolation
- EC2 rollback
- IP threat enrichment
- Tamper detection alerts
- Break-glass role usage alerts

Critical EventBridge and Lambda delivery paths use retry policies and DLQs so failed security events are retained for review instead of silently disappearing.

---

## Major Components

### Control Plane

Located at:

```text
bootstrap/control_plane
```

The **control plane** manages foundational platform resources.

Substacks include:

| Substack | Purpose |
|----------|---------|
| `state` | Creates the S3 state bucket and state CMK, then stores its own state in that remote backend after migration |
| `account` | Creates GitHub OIDC execution roles |
| `organizations` | Defines AWS Organizations OU structure |
| `identity_center` | Manages centralized IAM Identity Center access |

### Environment Stacks

Located at:

```text
environments/dev
environments/staging
environments/prod
```

Each environment stack deploys the security baseline into its respective AWS account.

Environment stacks include:

- Deployment profile and egress mode resolution
- VPC and subnets
- Dedicated VPC endpoint subnets
- AWS Network Firewall, when enabled by egress mode
- NAT Gateway, when required by egress mode
- VPC endpoints
- EC2 workloads with first-boot package updates
- Resource-level security-policy readiness before EC2 launch
- S3 storage
- KMS keys
- CloudTrail
- CloudWatch
- AWS Config, when enabled by profile or override
- GuardDuty
- Security Hub
- Inspector, when enabled by profile
- Lambda automation
- EventBridge rules and targets
- SNS topics
- SQS notification queues and DLQs
- Backup and patching resources
- IAM service roles and shared access policies

### Modules

Reusable Terraform modules live under:

```text
modules/
```

Each module contains its own `README.md` describing its purpose, inputs, outputs, and behavior.

---

## Deployment Profiles and Egress Modes

The baseline supports deployment profiles that set default cost/security behavior per environment.

| `deployment_profile` | Default `egress_mode` | AWS Config | Backup | Inspector | CloudWatch retention | Intended use |
|---|---|---:|---:|---:|---:|---|
| `production` | `network_firewall` | Enabled | Enabled | Enabled | 90 days | Full security baseline for sensitive workloads |
| `development` | `nat_only` | Enabled | Disabled | Enabled | 30 days | Lower-cost development and testing |
| `minimal` | `vpc_endpoints_only` | Disabled | Disabled | Disabled | 14 days | Lowest-cost/private AWS-only testing |

The profile sets defaults only. Explicit variables can override profile defaults.

For example:

```hcl
deployment_profile = "development"
egress_mode        = "network_firewall"
```

The baseline also supports explicit egress modes:

| `egress_mode` | Network Firewall | NAT Gateway | Compute private default route |
|---|---:|---:|---|
| `network_firewall` | Yes | Yes | Network Firewall endpoint |
| `nat_only` | No | Yes | NAT Gateway |
| `vpc_endpoints_only` | No | No | No default route |

When `egress_mode = "auto"`, the effective egress mode is selected from `deployment_profile`.

Important:

When `egress_mode = "vpc_endpoints_only"`, Network Firewall and NAT Gateways are not deployed, compute private subnets do not receive a default internet route, and the general compute TCP/443 egress rule is not created. This mode is intended for AWS-private testing or workloads that do not require external package repositories or third-party internet access. EC2 user data package installation and Patch Manager operations against public Ubuntu repositories require an approved package mirror or another explicitly provided path.

---

## Security Services

This baseline integrates several AWS-native security services:

| Service | Purpose |
|---------|---------|
| GuardDuty | Threat detection |
| Security Hub | Security findings aggregation |
| AWS Config | Compliance rule evaluation |
| CloudTrail | API activity logging |
| CloudWatch | Metrics, logs, and alarms |
| Inspector | Vulnerability scanning |
| EventBridge | Security event routing |
| SNS | Alert fanout and human notification |
| SQS | Durable notification queues and DLQs |
| KMS | Encryption key management |
| IAM Identity Center | Centralized human access |
| AWS Backup | Backup orchestration |
| SSM Patch Manager | Patch management |

Some services are profile-aware. For example, AWS Config and Inspector are enabled by default in `production` and `development`, while `minimal` disables them by default unless explicitly overridden.

### EC2 Vulnerability Remediation and Patching

Amazon Inspector package vulnerabilities may appear as Security Hub findings. The baseline addresses stale operating system package findings through two complementary controls:

1. **First-boot update:** each Ubuntu EC2 instance rewrites the standard Ubuntu package sources to HTTPS, refreshes APT metadata with retry behavior, runs `apt-get dist-upgrade -y`, installs `ca-certificates`, `curl`, and `jq`, and records selected package versions in `/var/log/instance-bootstrap.log`.
2. **Ongoing patching:** the `patch_management` module targets instances by `PatchGroup` tag and runs `AWS-RunPatchBaseline` during a scheduled SSM Maintenance Window with `Install` and `RebootIfNeeded`.

Selecting the latest Ubuntu AMI alone does not guarantee that all packages are current at launch. The first-boot update closes the gap between image publication and instance creation, while Patch Manager handles later baseline-approved patches.

The compute module sets `user_data_replace_on_change = true`, so changes to the bootstrap script replace the affected instances and apply the new first-boot configuration.

#### First-Boot Network Readiness

The compute security group is consumed by the nested networking `security_policy` module, so the entire compute module cannot depend on the entire networking module without creating a cycle. Instead, the baseline passes a `compute_sg_rule_ids` readiness object through:

```text
security_policy.compute_sg_rule_ids
        |
        v
networking.compute_sg_rule_ids
        |
        v
compute.terraform_data.compute_security_policy_ready
        |
        v
aws_instance.ec2
```

This resource-level dependency ensures the EC2 instances launch only after the required security group rules exist, including the conditional general HTTPS rule for `nat_only` and `network_firewall` modes. It prevents cloud-init from attempting Ubuntu repository access while Terraform is still creating the egress policy.

SSM connectivity by itself does not prove public repository connectivity. SSM can operate through Interface VPC Endpoints while Ubuntu APT traffic requires NAT, the approved Network Firewall path, or an internal package mirror.

---

## Automation Workflows

The baseline includes several security automation workflows.

### EC2 Isolation

The EventBridge rule receives new HIGH- and CRITICAL-severity Security Hub findings involving EC2 instances. The Lambda function then applies additional fail-closed eligibility checks before changing the instance.

Default behavior:

- Automatic isolation defaults to `CRITICAL` findings only.
- `AUTO_ISOLATION_SEVERITIES` can explicitly enable additional severities, such as `HIGH,CRITICAL`.
- The finding must be `ACTIVE` with workflow status `NEW`.
- The resource must be an EC2 instance in the `running` or `stopped` state.
- The instance must explicitly have `IsolationAllowed=true`.
- Already-isolated instances and duplicate instance references in the same invocation are skipped.

For an eligible instance, the workflow:

1. records the existing security groups;
2. requests tagged snapshots for attached EBS volumes;
3. fails closed if snapshot creation fails;
4. replaces the existing security groups with the quarantine security group;
5. adds isolation and recovery metadata tags; and
6. sends an SNS notification when a topic is configured.

The explicit `IsolationAllowed=true` requirement prevents a matching finding from isolating an instance unless the workload has opted into automatic response. The compute module defaults this authorization to `false`.

Terraform also ignores automation-managed changes to the instance security group attachments and isolation metadata tags. A routine `terraform apply` therefore does not automatically reattach the normal compute security group or remove the recovery context from an isolated instance.

### EC2 Rollback

Triggered manually through a controlled EventBridge event on the custom SecOps event bus.

This allows a SecOps operator to restore previously isolated EC2 instances after review and approval without granting operators broad direct EC2 modification access.

### IP Threat Enrichment

Enriches IP-related Security Hub findings using the configured threat intelligence source and sends the results to SNS. The function intentionally runs outside a VPC so it can reach the external API without requiring NAT.

### Lambda Deployment Packaging

The automation module packages its three Lambda source files with managed Terraform `archive_file` resources:

```text
lambda/ec2_isolation.py  -> lambda/ec2_isolation.zip
lambda/ec2_rollback.py   -> lambda/ec2_rollback.zip
lambda/ip_enrichment.py  -> lambda/ip_enrichment.zip
```

The ZIP files are generated build outputs rather than manually maintained source artifacts. The Lambda functions depend directly on the matching archive resources, so Terraform creates each package before creating or updating the function.

This resource-based packaging is required by the plan-before-approval workflow. Plan and Apply run on separate GitHub Actions runners, and the protected Apply job can execute the archive-resource operations contained in the reviewed saved plan. No Lambda filename list or ZIP-copying logic is required in the workflow. Adding a future Lambda should remain encapsulated within the Terraform module.

### Tamper Detection

Detects attempts to disable, delete, or modify critical security services such as:

- CloudTrail
- GuardDuty
- Security Hub
- AWS Config
- KMS

### Break-Glass Monitoring

Detects use of the break-glass administrator role and sends a high-priority alert.

### Notification and Failure Retention

Security and compliance notifications use encrypted SNS and SQS resources so alerts can be delivered to humans while also being retained for operational review.

Key paths include:

- Compliance notifications: compliance SNS topic to compliance SQS queue
- Security notifications: security notifications SNS topic to security notifications SQS queue
- Security notification queue failures: security notifications SQS queue to security notifications DLQ
- EventBridge-to-SNS delivery failures: shared security notifications EventBridge DLQ
- Automation workflow failures: dedicated EC2 Isolation, EC2 Rollback, and IP Enrichment DLQs

The DLQs are terminal failure-retention queues. They are intended for SecOps review, troubleshooting, and manual replay or remediation where appropriate.

### CI/CD

GitHub Actions workflows use GitHub OIDC to assume environment-specific AWS IAM roles without storing long-lived AWS access keys.

Typical workflows include:

- `Terraform Plan`
- `Terraform Apply`
- `Reconcile Workload Account`
- `Terraform Destroy`
- `Terraform Static Analysis`
- `Docs Validation`
- `Lint PR`
- `Workload Bootstrap Evidence Export`
- `Workload Baseline Evidence Export`
- `Control-Plane Evidence Export`

Workload deployment workflows use separate Plan and Apply GitHub environments:

```text
dev-plan        -> dev GitHub-Plan role
dev             -> dev GitHub-Apply role

staging-plan    -> staging GitHub-Plan role
staging         -> staging GitHub-Apply role

prod-plan       -> prod GitHub-Plan role
prod            -> prod GitHub-Apply role

control-plane-plan -> control-plane GitHub-Plan role
control-plane      -> control-plane GitHub-Apply role
```

The separate `*-plan` environments are intentional. Plan jobs run without protected Apply-environment approval so the Terraform plan exists before a reviewer is asked to approve deployment. Apply jobs target the protected `dev`, `staging`, or `prod` environment and begin only after its required review rules pass.

`Terraform Apply` uses a plan-first workflow:

1. assume the Plan role through the selected `*-plan` environment;
2. generate a saved Terraform plan;
3. publish the readable plan in the workflow summary;
4. upload the binary plan with metadata and a checksum;
5. wait for approval on the protected Apply environment;
6. verify the artifact and workflow context; and
7. apply the exact saved plan without generating a replacement plan.

Managed `archive_file` resources allow the exact saved-plan model to work across separate runners: the protected Apply runner creates the required Lambda ZIP files as Terraform resources before the dependent Lambda functions are deployed.

The workflow can optionally invoke `Reconcile Workload Account` after the baseline apply. Reconciliation follows the same plan-first pattern: it resolves the current workload-created CMKs, publishes and stores a saved account-stack plan, waits for approval, applies that exact plan, and runs strict bootstrap validation.

`ACCOUNT_ID` is required in both members of each Plan/Apply environment pair. Both baseline and reconciliation jobs validate that the configured role ARN and active AWS caller belong to that account.

The baseline saved-plan metadata additionally records the expected AWS account ID together with the environment, commit, repository, workflow run, attempt, and Terraform version. Reconciliation verifies its checksum and workflow-context metadata, while its Plan and Apply jobs independently repeat the account and caller checks.

Other shared environment values should remain synchronized across each Plan/Apply pair.

The layer-specific evidence workflows use the applicable `*-plan` GitHub environment and Plan role. For migrated state stacks, those workflows materialize the ignored runtime `backend.tf` before running `terraform init` and read-only validation.

## Deployment Order

At a high level, deployment follows this order:

1. Initialize and apply each **state** stack locally so it can create its S3 state bucket and state CMK.
2. Run `scripts/bootstrap/migrate-state-stack.sh <target>` to materialize `backend.tf`, migrate the state stack into S3, and verify the remote state.
3. Deploy **account / GitHub OIDC** resources.
4. Deploy the **AWS Organizations** structure.
5. Deploy the **environment baseline** locally or through the plan-first `Terraform Apply` workflow.
6. Reconcile the current workload-created CMK permissions into the GitHub Apply role:
   - locally with `scripts/bootstrap/reconcile-workload-account.sh`; or
   - through the plan-first `Reconcile Workload Account` workflow.
   The `Terraform Apply` workflow can invoke reconciliation automatically after a successful baseline apply.
7. Deploy or re-apply **IAM Identity Center** assignments.
8. Validate **security automation workflows**.
9. Export validation evidence for the applicable validation layers.

Supported migration targets are:

```text
dev
staging
prod
control-plane
```

Detailed instructions are provided in:

```text
docs/quickstart.md
scripts/bootstrap/README.md
```

## Validation

The repository includes safe, read-only validation scripts under:

```text
scripts/validation/
```

Validation is split into three layers, with matching evidence exporters:

```text
Workload bootstrap validation  -> validate-bootstrap.sh <dev|staging|prod>
Workload baseline validation   -> validate-baseline.sh <dev|staging|prod>
Control-plane validation       -> validate-control-plane.sh

Workload bootstrap evidence    -> export-bootstrap.sh <dev|staging|prod>
Workload baseline evidence     -> export-baseline.sh <dev|staging|prod>
Control-plane evidence         -> export-control-plane.sh
```

### Workload Bootstrap Validation

Use `validate-bootstrap.sh` to validate workload bootstrap resources such as Terraform state backend configuration, state bucket security, state CMK configuration, GitHub OIDC roles, and GitHub role access to state and workload-created CMKs.

```bash
AWS_PAGER="" \
AWS_PROFILE=dev \
AWS_REGION=us-east-1 \
EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" \
CLOUD_NAME="tf-secure-baseline" \
REQUIRE_STATE_STACK_REMOTE=true \
./scripts/validation/validate-bootstrap.sh dev
```

When `REQUIRE_STATE_STACK_REMOTE=true`, validation confirms that the state stack:

- has an active S3 backend
- uses `use_lockfile = true`
- uses the expected shared bucket and region
- uses a state key distinct from the account and workload stacks
- has a readable state object in S3
- supports `terraform state pull`
- reports a `tf_state_bucket_name` output matching the configured backend bucket

Direct script execution defaults `REQUIRE_STATE_STACK_REMOTE` to `false`, making migration findings advisory. The GitHub evidence workflow defaults it to `true`.

For a fresh checkout of an already-migrated deployment, materialize the ignored runtime backend file from the tracked template before initialization:

```bash
cp bootstrap/dev/state/backend.tf.migrated.example \
  bootstrap/dev/state/backend.tf

terraform -chdir=bootstrap/dev/state init -input=false
terraform -chdir=bootstrap/dev/account init -input=false
terraform -chdir=environments/dev init -input=false
```

The workload bootstrap evidence workflow performs the state-stack backend materialization and initialization automatically.

Bootstrap validation is strict by default for workload-created CMK policy evidence. `STRICT_WORKLOAD_CMK_POLICY_CHECKS` defaults to `true`, which means stale or missing GitHub Apply role policy references to the current workload Lambda and Secrets Manager CMKs fail validation. After applying a workload baseline, reconcile the account stack through the `Reconcile Workload Account` workflow or the local helper. For a local two-step review that applies the exact reviewed file, generate it with `--plan-file` and apply it with `--apply-plan`. The one-step `--apply` mode generates, displays, confirms, and applies a saved plan within the same invocation. Both apply paths run strict bootstrap validation unless `--skip-validation` is used. Set `STRICT_WORKLOAD_CMK_POLICY_CHECKS=false` only for transitional validation where those checks should be warnings instead of failures.

### Workload Baseline Validation

Use `validate-baseline.sh` to validate deployed workload baseline resources.

```bash
AWS_PAGER="" \
AWS_PROFILE=dev \
AWS_REGION=us-east-1 \
EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
CLOUD_NAME="tf-secure-baseline" \
./scripts/validation/validate-baseline.sh dev
```

The workload baseline validation suite checks deployed environments for account identity, Terraform outputs, networking, VPC endpoints, logging, security services, KMS, Backup, SNS, SQS, EventBridge, Lambda, SSM, Compute, and IAM posture. It also validates notification and failure-retention paths such as SNS subscriptions, SQS queues, EventBridge target DLQs, retry policies, and Lambda workflow wiring.

For Inspector or Security Hub package findings, also confirm that the instance is SSM `Online`, review `/var/log/instance-bootstrap.log`, verify Ubuntu repository connectivity through the effective egress path, and inspect Patch Manager execution and compliance history. An SSM-online result confirms AWS management connectivity but does not by itself confirm access to public Ubuntu repositories.

A successful workload baseline validation run should end with:

```text
Validation scripts passed:  14/14
Validation scripts failed:  0/14
```

A clean CI/CD regression test should also confirm that a fresh Plan runner and fresh Apply runner can deploy all three Lambda functions without pre-existing ZIP files. The Apply run should create the managed archive resources before the Lambda functions and should not report `reading ZIP file: no such file or directory`.

Individual scripts can also be run directly when troubleshooting a specific architecture area.

### Control-Plane Validation

Use `validate-control-plane.sh` to validate control-plane bootstrap and governance resources.

```bash
AWS_PAGER="" \
AWS_PROFILE=control-plane \
AWS_REGION=us-east-1 \
EXPECTED_ACCOUNT_ID="<CONTROL-PLANE-ACCOUNT-ID>" \
EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" \
ACCOUNT_ID_DEV="<DEV-ACCOUNT-ID>" \
ACCOUNT_ID_STAGING="<STAGING-ACCOUNT-ID>" \
ACCOUNT_ID_PROD="<PROD-ACCOUNT-ID>" \
CLOUD_NAME="tf-secure-baseline" \
REQUIRE_STATE_STACK_REMOTE=true \
./scripts/validation/validate-control-plane.sh
```

Control-plane validation checks the state backend resources, optional strict proof that the control-plane state stack is remotely readable, GitHub OIDC roles, AWS Organizations OU structure, IAM Identity Center instance discovery, permission sets, groups, and optional account assignment presence.

For a fresh checkout of an already-migrated deployment, materialize the control-plane state backend and initialize all four control-plane Terraform roots:

```bash
cp bootstrap/control_plane/state/backend.tf.migrated.example \
  bootstrap/control_plane/state/backend.tf

terraform -chdir=bootstrap/control_plane/state init -input=false
terraform -chdir=bootstrap/control_plane/account init -input=false
terraform -chdir=bootstrap/control_plane/organizations init -input=false
terraform -chdir=bootstrap/control_plane/identity_center init -input=false
```

The control-plane evidence workflow performs this materialization and initialization automatically and defaults `REQUIRE_STATE_STACK_REMOTE` to `true`.

Detailed validation guidance is provided in:

```text
scripts/validation/README.md
docs/validation-checklist.md
```

The validation scripts and evidence workflows are read-only. Terraform plan/apply/destroy workflow validation, end-user Identity Center login testing, live Lambda workflow tests, tamper tests, break-glass tests, and destroy safety review remain manual validation activities.

### Validation Reporting

Validation evidence can be exported for client handoff, troubleshooting, or internal deployment records.

Each validation layer has its own exporter and output directory:

| Validation layer | Export script | Output directory |
|---|---|---|
| Workload bootstrap | `export-bootstrap.sh <dev/staging/prod>` | `validation-results/<environment>/bootstrap/<timestamp>/` |
| Workload baseline | `export-baseline.sh <dev/staging/prod>` | `validation-results/<environment>/baseline/<timestamp>/` |
| Control plane | `export-control-plane.sh` | `validation-results/control-plane/<timestamp>/` |

Example workload bootstrap evidence export:

```bash
AWS_PROFILE="dev" \
AWS_REGION="us-east-1" \
EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" \
CLOUD_NAME="tf-secure-baseline" \
./scripts/validation/export-bootstrap.sh dev
```

Example workload baseline evidence export:

```bash
AWS_PROFILE="dev" \
AWS_REGION="us-east-1" \
EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
CLOUD_NAME="tf-secure-baseline" \
./scripts/validation/export-baseline.sh dev
```

Example control-plane evidence export:

```bash
AWS_PROFILE="control-plane" \
AWS_REGION="us-east-1" \
EXPECTED_ACCOUNT_ID="<CONTROL-PLANE-ACCOUNT-ID>" \
EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" \
ACCOUNT_ID_DEV="<DEV-ACCOUNT-ID>" \
ACCOUNT_ID_STAGING="<STAGING-ACCOUNT-ID>" \
ACCOUNT_ID_PROD="<PROD-ACCOUNT-ID>" \
CLOUD_NAME="tf-secure-baseline" \
./scripts/validation/export-control-plane.sh
```

Each report package includes:

- `summary.md`
- `summary.json`
- one or more validation logs

Generated validation results are ignored by Git by default.

Additional validation evidence guidance is provided in:

```text
docs/assurance/validation-report-template.md
docs/assurance/validation-evidence-guide.md
```

---

## State Management

Terraform state is separated by **stack** and **environment**.

The state stacks follow a two-phase lifecycle:

```text
1. No active backend.tf:
   initialize and apply locally to create the S3 bucket and state CMK

2. Post-deployment migration:
   materialize backend.tf from backend.tf.migrated.example
   run scripts/bootstrap/migrate-state-stack.sh <target>
   verify the remote S3 object and terraform state pull
```

The tracked `backend.tf.migrated.example` files document the post-migration configuration. Active state-stack `backend.tf` files are generated locally or by GitHub evidence workflows and are ignored by Git.

Example workload state layout:

```text
bootstrap/state/dev.tfstate
bootstrap/dev.tfstate
baseline/dev.tfstate

bootstrap/state/staging.tfstate
bootstrap/staging.tfstate
baseline/staging.tfstate

bootstrap/state/prod.tfstate
bootstrap/prod.tfstate
baseline/prod.tfstate
```

Control-plane substacks use separate state files:

```text
control-plane/state.tfstate
control-plane/account.tfstate
control-plane/identity-center.tfstate
control-plane/organizations.tfstate
```

All remote-backed stacks use S3 native state locking with `use_lockfile = true`. The state-stack migration helper refuses to overwrite an existing destination object, creates external pre-migration backups, and verifies the remote state after migration.

This separation prevents accidental cross-stack changes and reduces the blast radius of Terraform operations.

## Cost Considerations

This baseline supports multiple cost/security profiles.

The full production-style baseline uses AWS Network Firewall for centralized egress inspection. AWS Network Firewall provides strong security controls, but it can increase cost, especially when deployed across multiple environments and Availability Zones.

Recommended usage:

- Use `deployment_profile = "production"` for production or sensitive workloads.
- Use `deployment_profile = "development"` for lower-cost development/testing environments.
- Use `deployment_profile = "minimal"` for private AWS-only testing where general internet access is not required.
- Review NAT Gateway, Network Firewall, VPC endpoint, CloudWatch, logging, SNS/SQS, Inspector, AWS Config, and Backup costs regularly.

Cost-sensitive behavior includes:

| Setting | Production | Development | Minimal |
|---|---:|---:|---:|
| Network Firewall | Enabled | Disabled by default | Disabled |
| NAT Gateway | Enabled | Enabled | Disabled |
| AWS Config | Enabled | Enabled | Disabled by default |
| Inspector | Enabled | Enabled | Disabled |
| AWS Backup | Enabled | Disabled | Disabled |
| CloudWatch retention | 90 days | 30 days | 14 days |

The exact behavior can be overridden with explicit variables where supported.

---

## Documentation

System-level documentation is located in:

```text
docs/
```

Important docs include:

| Document | Purpose |
|----------|---------|
| docs/quickstart.md | End-to-end deployment guide |
| docs/architecture-overview.md | Architecture explanation |
| docs/design-principles.md | Design principles and rationale |
| docs/adoption-guide.md | Guidance for adapting the baseline |
| docs/validation-checklist.md | Post-deployment validation checklist |
| docs/assurance/ | Validation evidence, report templates, and compliance-oriented documentation |
| docs/lambda_tests/ | Automation testing documentation |

Each module also includes its own local README.md.

---

## Release Status and Highlights

### Current Published Release: `v1.5.0`

`v1.5.0` was tagged and published on July 18, 2026. The release tag must not be moved or rewritten. Changes merged into `main` after that tag remain unreleased until a later release is created.

#### Added

- Added plan-first `Terraform Apply` execution that publishes the readable workload plan before approval, uploads the exact binary plan as a short-lived artifact, and applies only that reviewed plan after the protected environment is approved.
- Added optional post-baseline workload-account reconciliation to the `Terraform Apply` workflow.
- Added plan-first `Reconcile Workload Account` execution with `plan-only` and `plan-and-apply` modes.
- Added `--plan-file` and `--apply-plan` support to `scripts/bootstrap/reconcile-workload-account.sh` for durable local plan review and exact saved-plan application across separate invocations.
- Added saved-plan metadata and SHA-256 verification for baseline and reconciliation Apply jobs. Baseline metadata also records the expected AWS account ID.
- Added workload Plan and Apply account-safety validation for `ACCOUNT_ID`, configured role ARN account ownership, and active AWS caller identity.

#### Changed

- Standardized workload deployment on paired GitHub environments: `dev-plan` / `dev`, `staging-plan` / `staging`, and `prod-plan` / `prod`.
- Moved approval to the Apply job so reviewers can inspect the Terraform plan before approving deployment.
- Updated reconciliation automation to apply the exact saved account-stack plan rather than regenerating a plan after approval.
- Updated GitHub OIDC execution so an unset `AWS_PROFILE` uses the AWS default credential provider chain, while local profile-based operation remains supported.
- Updated deployment, adoption, validation, and bootstrap-script documentation for the final plan-before-apply CI/CD model.

### Unreleased Changes on `main`

Changes completed after the `v1.5.0` release include:

- Replaced plan-time Lambda archive data sources with managed `archive_file` resources for EC2 isolation, EC2 rollback, and IP enrichment.
- Confirmed that a reviewed saved plan can create the Lambda packages on a fresh protected Apply runner without workflow-specific ZIP handling.
- Hardened EC2 automatic isolation with an explicit `IsolationAllowed=true` opt-in requirement.
- Changed the default automatic-isolation severity to `CRITICAL`, with `AUTO_ISOLATION_SEVERITIES` available for explicit expansion.
- Added ACTIVE/NEW finding checks, instance-state checks, duplicate and already-isolated detection, and fail-closed pre-isolation EBS snapshot behavior.
- Added Terraform drift protection so routine applies do not release isolated EC2 instances or remove automation-managed isolation metadata.
- Updated the Ubuntu EC2 bootstrap to use HTTPS package sources, retry APT operations, run a first-boot distribution upgrade, install required operational packages, and record relevant package versions.
- Enabled EC2 replacement when user data changes through `user_data_replace_on_change`.
- Added the `security_policy -> networking -> compute` `compute_sg_rule_ids` readiness chain so EC2 instances wait for required security group rules before cloud-init runs.
- Made general compute TCP/443 egress conditional on the effective egress mode and omitted it for `vpc_endpoints_only`.
- Updated the compute, networking security-policy, patch-management, root-level, and changelog documentation for the vulnerability-remediation and first-boot dependency changes.

These changes are not part of the immutable `v1.5.0` tag and should remain under `Unreleased` in `CHANGELOG.md` until a later version is tagged.

For previous release highlights and detailed change history, see `CHANGELOG.md`.

## Future Roadmap

Potential future improvements include:

- Improve dashboarding and visual evidence outputs
- Add configurable VPC endpoint service lists
- Add additional deployment profile-controlled services
- Add SCP strategy and Terraform implementation
- Add cross-account GuardDuty aggregation
- Add cross-account Security Hub aggregation
- Add org-level validation scripts for SCP / GuardDuty / Security Hub aggregation
- Optional dummy SaaS app using fake data

---

## Intended Audience

This project is intended for:

- Cloud security engineers
- DevSecOps engineers
- Platform engineers
- SaaS founders
- Security consultants
- Teams preparing for SOC 2 / ISO 27001

---

## Summary

`tf-secure-baseline` is a deployable AWS security foundation for sensitive workloads.

It combines multi-account architecture, centralized identity, secure networking, deployment profiles, configurable egress modes, dependency-safe EC2 first boot, first-boot and scheduled patching, durable notification paths, fail-closed automated response, Terraform-managed Lambda packaging, and plan-before-approval GitHub OIDC CI/CD into a **reusable Terraform platform**.

The goal is to provide a **secure-by-default foundation** that can be adapted, extended, and used as the starting point for production SaaS environments.