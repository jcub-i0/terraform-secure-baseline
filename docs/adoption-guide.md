# Adoption Guide - tf-secure-baseline

## Purpose

This guide helps teams determine when and how to adopt `tf-secure-baseline`.

It explains:

- Who this baseline is designed for
- What problems it helps solve
- What maturity level it assumes
- How teams should customize it
- What should be completed before production use
- What this baseline does and does not provide

For deployment instructions, see:

```text
docs/quickstart.md
```

For architecture details, see:

```text
docs/architecture-overview.md
```

---

## Intended Audience

`tf-secure-baseline` is designed for teams that need a secure AWS foundation without building every control from scratch.

It is especially useful for:

- SaaS companies handling customer PII
- Startups preparing for SOC 2 or ISO 27001
- Small and mid-sized engineering teams
- Cloud security teams building reusable AWS patterns
- Platform teams standardizing environment deployments
- Consultants implementing secure AWS foundations for clients

The baseline is opinionated, but it is intended to be adaptable.

---

## When to Use This Baseline

Use this baseline when your AWS environment needs:

- Multi-account environment separation
- Private-by-default infrastructure
- Centralized logging
- Continuous monitoring
- IAM Identity Center-based human access
- GitHub OIDC-based CI/CD access
- Centralized Security Hub CSPM and GuardDuty governance
- Security Hub V2 workload policy governance
- AWS Config posture monitoring
- Event-driven incident response
- Automated EC2 isolation
- Controlled rollback workflows
- IP threat enrichment
- Tamper detection
- Break-glass monitoring
- Backup and patch management foundations
- Configurable cost/security profiles
- Configurable egress behavior
- Private AWS service access through dedicated VPC endpoint subnets

This project is most appropriate when the environment is expected to host persistent workloads that handle sensitive data or support production-like systems.

---

## Target Use Cases

### SaaS Application Environments

This baseline is well suited for SaaS applications that process or store sensitive customer data.

Examples:

- Customer portals
- Internal admin applications
- APIs handling PII
- Data processing services
- Tenant-facing workloads
- Backend services supporting regulated workflows

---

### SOC 2 / ISO 27001 Readiness

This baseline can support evidence collection and technical control implementation for areas such as:

- Access control
- Logging and monitoring
- Change management
- Encryption
- Incident response
- Vulnerability management
- Backup and recovery
- Infrastructure security
- Network segmentation
- Controlled egress

It does **not** guarantee compliance or certification by itself.

Policies, procedures, human review, vendor management, risk management, and audit evidence are still required.

---

### Consulting and Client Deployments

This baseline can be used as a reusable implementation foundation for client environments.

It provides a repeatable structure for:

- Account and OU separation
- Terraform state management
- GitHub OIDC setup
- Centralized identity
- Delegated security administration
- Logging
- Detection
- Response automation
- Deployment profile selection
- Egress mode selection
- Private AWS service connectivity

Consultants can adapt the modules, naming conventions, email targets, regions, enabled services, deployment profiles, and egress modes to match client requirements.

---

## Problems This Helps Solve

This baseline helps address common AWS security and operational problems, including:

- Workloads deployed with public IPs by default
- Flat single-account AWS environments
- Lack of environment separation
- Long-lived CI/CD access keys
- Terraform applies approved before a reviewable plan exists
- Weak or inconsistent logging
- No centralized detection or security-administration layer
- Inconsistent Security Hub / GuardDuty / Config coverage
- Limited incident containment capability
- Manual and inconsistent incident response
- Lack of tamper detection
- No controlled rollback workflow
- Poor visibility into break-glass access
- Unclear Terraform state ownership
- Long-lived bootstrap state stored only on an operator workstation
- Terraform stacks destroying their own execution roles
- IAM policy delete conflicts caused by unmanaged dependencies
- Unrestricted outbound access through NAT Gateway
- Unclear cost/security tradeoffs between environments
- VPC endpoint ENIs competing with workload ENIs in compute subnets

---

## What This Baseline Provides

Deploying this baseline provides a production-aligned AWS security foundation with:

- Multi-account architecture with dedicated `control-plane`, `security-operations`, `dev`, `staging`, and `prod` accounts
- Control-plane and delegated security-administration separation
- Environment-specific, encrypted remote Terraform state with S3 native locking
- GitHub OIDC CI/CD roles
- Plan-before-apply deployment workflows with protected approvals and exact saved-plan application
- IAM Identity Center groups and permission sets
- Private VPC networking
- Deployment profiles
- Configurable egress modes
- AWS Network Firewall egress inspection, when enabled
- NAT Gateway egress, when required
- Dedicated private subnets for Interface VPC Endpoints
- VPC endpoints
- A preferred ECS/Fargate application runtime with one shared cluster per environment
- KMS-encrypted ECR repositories, digest-pinned task definitions, per-service IAM/task SGs, and an optional shared HTTPS ALB
- Centralized logging
- KMS-backed encryption
- CloudTrail
- AWS Config, when enabled
- Centralized GuardDuty organization administration and Runtime Monitoring
- Centralized Security Hub CSPM configuration and workload policy associations
- Security Hub V2 organization policy governance for the `Workloads` OU
- Inspector, when enabled
- EventBridge rules
- SNS alerts
- EC2 isolation automation
- EC2 rollback workflow
- IP enrichment workflow
- Tamper detection
- Break-glass monitoring
- AWS Backup, when enabled
- SSM Patch Manager

---

## What This Baseline Does Not Provide

This baseline is not a complete security program by itself.

It does **not** provide:

- Guaranteed SOC 2 or ISO 27001 certification
- 24/7 SOC monitoring
- Managed incident response
- Full enterprise landing zone functionality
- Account vending automation
- Complete SCP strategy
- Application-layer zero trust
- Service mesh
- Full SIEM integration
- Threat hunting operations
- Secure SDLC process
- Application vulnerability scanning
- Vendor risk management
- Business continuity planning
- Human policy enforcement
- General internet access in `vpc_endpoints_only` mode
- Private connectivity to AWS services that do not have configured VPC endpoints

It provides technical cloud security foundations that should be paired with organizational controls and operational processes.

---

## Baseline, Not One-Size-Fits-All

`tf-secure-baseline` is intended to be a **secure starting point**, not a universal product that fits every organization without changes.

It provides opinionated defaults for common SaaS security needs, but every organization should review and adapt the baseline based on:

- Application architecture
- Data sensitivity
- Compliance requirements
- Network requirements
- Existing identity model
- CI/CD tooling
- Budget constraints
- Operational maturity
- Required egress behavior
- Required AWS service endpoint coverage

The goal is to provide a strong foundation that teams can safely extend, not to replace environment-specific design decisions.

---

## Deployment Profiles and Egress Modes

The baseline supports deployment profiles that set environment-appropriate defaults.

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

When `egress_mode = "auto"`, the effective egress mode is selected from the `deployment_profile`.

Profiles define defaults, not hard limits. Explicit variables can override profile defaults when needed.

Example:

```hcl
deployment_profile = "development"
egress_mode        = "network_firewall"
```

This allows a development environment to use production-style Network Firewall inspection when required.

Important:

When `egress_mode = "vpc_endpoints_only"`, NAT Gateways and Network Firewall are not deployed, and private compute subnets do not receive a default internet route. This mode is intended for AWS-private testing or workloads that do not require external package repositories, public container registries, third-party APIs, or general internet access.

---

## Adoption Maturity

### Good Fit

This baseline is a good fit if your team:

- Has or plans to have multiple AWS accounts
- Uses Terraform or wants to standardize on Terraform
- Uses GitHub Actions or wants OIDC-based CI/CD
- Needs secure defaults for AWS infrastructure
- Wants centralized access through IAM Identity Center
- Needs better logging, detection, and response
- Is preparing for audit or customer security review
- Wants clear cost/security profiles for dev, staging, and prod
- Has at least one engineer comfortable operating AWS and Terraform
- Runs modern long-lived Linux application services on ECS/Fargate, or retains the supported EC2 workload pattern

---

### Possible Fit with Customization

This baseline may still work, but will require more customization if your team:

- Uses GitLab, Azure DevOps, or another CI/CD system
- Uses a different identity provider model
- Needs different region or naming conventions
- Already has a central networking account
- Already has a SIEM/logging pipeline
- Requires multi-region failover
- Uses Kubernetes or another container orchestrator instead of the implemented ECS/Fargate runtime
- Requires a different centralized security-services ownership model
- Requires custom egress paths or proxy-based internet access
- Requires additional VPC endpoints beyond the default endpoint set

---

### Poor Fit

This baseline may not be appropriate if your environment is:

- Fully air-gapped
- Extremely short-lived or experimental
- Not intended to host persistent workloads
- Already managed by a mature enterprise landing zone
- Required to follow a very different internal cloud operating model
- Optimized primarily for lowest possible AWS cost
- Designed for hyperscale workloads out of the box
- Dependent on broad unrestricted outbound internet access from private workloads

---

## Recommended Adoption Path

Adopt the baseline in stages.

Do not attempt to customize everything before the first successful deployment.

---

## Phase 1 - Review Architecture

Start by reviewing:

```text
docs/architecture-overview.md
docs/design-principles.md
docs/quickstart.md
```

Confirm that the model aligns with your intended AWS account strategy.

Key decisions:

- Will you use `dev`, `staging`, and `prod` workload accounts?
- Will you use separate `control-plane` and `security-operations` accounts?
- Will the `security-operations` account be the delegated administrator for centralized Security Hub and GuardDuty?
- Will GitHub Actions manage Terraform?
- Will IAM Identity Center be used for human access?
- Which AWS region will be primary?
- Who receives security notifications?
- Which deployment profile should each environment use?
- Which egress mode should each environment use?
- Will the workload use EC2, ECS/Fargate, or both?
- Which immutable ECR digest and optional ALB ingress rules will each ECS service use?

### Terraform Variable Templates

The repository provides tracked `terraform.tfvars.example` files as configuration templates. Copy the applicable template to `terraform.tfvars`, replace the example values with client- or environment-specific configuration, and keep the runtime file local. Runtime `.tfvars` files are ignored by Git and should never be committed; CI/CD values should be managed through protected GitHub variables and secrets.

---

## Phase 2 - Prepare AWS Accounts

Create or identify the required AWS accounts:

```text
control-plane
security-operations
dev
staging
prod
```

The control-plane account should manage:

- AWS Organizations
- IAM Identity Center
- Control-plane Terraform state and GitHub OIDC roles
- Organization-level prerequisites for delegated Security Hub, GuardDuty, and Security Hub V2 governance

The security-operations account should host:

- its own Terraform state and GitHub OIDC roles
- delegated Security Hub CSPM administration
- delegated GuardDuty administration and organization protection-plan configuration
- Security Hub V2 administrator-side configuration and workload organization policy management

Workload accounts should host:

- Dev, staging, and prod baseline infrastructure and workload GitHub OIDC resources
- workload-local Config, Inspector, logging, remediation, and response automation
- workload-local ECR, ECS/Fargate, ALB, IAM, and security-policy resources configured through the canonical `ecs_services` map

---

## Phase 3 - Choose Deployment Profiles

Before deploying each environment, choose the deployment profile and egress behavior.

Recommended starting point:

| Environment | Recommended `deployment_profile` | Recommended `egress_mode` |
|---|---|---|
| `dev` | `development` | `auto` |
| `staging` | `development` or `production` | `auto` |
| `prod` | `production` | `auto` |

For early testing, deploy `dev` first with:

```hcl
deployment_profile = "development"
egress_mode        = "auto"
```

This provides a lower-cost development environment while keeping key detection and posture services enabled.

Use `production` for workloads that need the full security baseline, including Network Firewall egress inspection and backup by default.

Use `minimal` only when the lack of general internet access is acceptable.

---

## Phase 4 - Deploy the Baseline

Follow `docs/quickstart.md` for the full deployment sequence. At a high level: bootstrap/control-plane and security-operations foundations first, then workload state/account stacks, then workload environments, reconciliation, Identity Center, and the four validation/evidence layers.

For ECS/Fargate applications, register each service in the tracked canonical `environments/<env>/container-workloads.auto.tfvars.json`. A new service may use `image_digest = null` so Terraform can create/retain its required ECR repository without creating the runtime before an image exists.

Application release then follows the implemented workflow:

```text
registered service
  -> Deploy Application
  -> branch-trusted Image Publisher role builds/pushes image
  -> authoritative ECR digest
  -> separate GitHub-only release job updates one digest
  -> release PR
  -> human review/merge
  -> separate protected Terraform Apply
  -> ECS convergence
  -> separate validation/evidence
```

Terraform does not build or push images. `Deploy Application` does not automatically merge the release PR, invoke Terraform Apply, or run evidence. This separation keeps application artifact publication, source-control mutation, infrastructure approval, and validation independently reviewable.

Deploy `dev` first and prove the full path before extending the same service/application configuration to staging or production.

## Phase 5 - Validate Controls

After deployment, review:

```text
docs/validation-checklist.md
```

Then run the Lambda workflow tests located at:

```text
docs/lambda_tests/ec2_isolation.md
docs/lambda_tests/ec2_rollback.md
docs/lambda_tests/ip_enrichment.md
```

Do not consider the environment production-ready until validation completes successfully.

Verify each migrated state stack before relying on downstream validation:

```bash
AWS_PROFILE=dev \
EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
./scripts/bootstrap/migrate-state-stack.sh dev --verify-only
```

For client-readiness or release evidence, use `REQUIRE_STATE_STACK_REMOTE=true` for direct bootstrap and control-plane validation. The GitHub evidence workflows enforce this by default.

Run the layer-specific evidence paths rather than treating workload validation as proof of central governance:

- **Export Control Plane Evidence** for Organizations topology, account placement, delegated-administrator prerequisites, and Identity Center.
- **Export Security Operations Evidence** for centralized Security Hub CSPM, GuardDuty, and Security Hub V2.
- **Export Bootstrap Evidence** for workload bootstrap/state/OIDC controls.
- **Export Baseline Evidence** for workload-local control realization.

Also confirm:

- Effective deployment profile outputs are correct.
- Effective egress mode resolved as expected.
- Network Firewall and NAT Gateway deployment matches the selected egress mode.
- Dedicated endpoint private subnets exist.
- Terraform manages the `guardduty-data` Interface Endpoint in those endpoint subnets.
- Interface VPC Endpoints are created before EC2 and are deployed into endpoint private subnets.
- S3 Gateway Endpoint is associated with the intended private route tables.
- AWS Config, Backup, Inspector, and CloudWatch retention match the selected profile or explicit overrides.

---

## Phase 6 - Customize for Your Organization

After a successful deployment, customize the baseline for your environment.

Common customization areas include:

- Naming conventions
- State backend bucket names, object keys, regions, and `backend.tf.migrated.example` templates
- AWS regions
- CIDR ranges
- Number of Availability Zones
- Deployment profile per environment
- Egress mode per environment
- SecOps email recipients
- GitHub organization and repository names
- IAM Identity Center groups
- Permission set behavior
- Central Security Hub CSPM policy/standard selection
- GuardDuty organization protection-plan settings
- AWS Config rules
- VPC endpoint coverage
- Canonical `ecs_services` definitions, immutable image digests, and optional shared-ALB routing
- Backup retention
- Patch windows
- Tags
- KMS key aliases and policies
- Network Firewall rules
- Lambda alert formatting

---

## Phase 7 - Production Readiness Review

Before using the baseline for production workloads, review:

- Terraform state protection and successful state-stack migration
- GitHub environment protections
- Required reviewers for prod apply workflows
- IAM Identity Center assignments
- Break-glass access procedure
- SNS subscription confirmation
- CloudTrail logging status
- Security Hub and GuardDuty delegated-administrator state
- Security Hub CSPM workload policy associations
- GuardDuty organization protection plans and Runtime Monitoring
- Security Hub V2 effective workload policy
- Workload-local AWS Config and Inspector status
- Backup policies
- Patch management settings
- Egress mode behavior
- VPC endpoint coverage
- Dedicated endpoint subnet placement
- Cost estimates
- Destruction/cleanup procedure
- Incident response runbooks

---

## Configuration Decisions

Before adopting this baseline, answer the following questions:

### Account Strategy

- Will each workload environment use a separate AWS account?
- Which account is the AWS Organizations management account?
- Will `control-plane` and `security-operations` be separate from workload accounts?
- Will `security-operations` be the delegated administrator for centralized Security Hub and GuardDuty?
- Who owns each account?

---

### Terraform State Strategy

- What bucket name will each workload, control-plane, and security-operations state stack use?
- What distinct object key will each Terraform root use?
- Who is authorized through `bucket_admin_principals`?
- Where will migration backups be retained?
- Who is responsible for running and approving state-stack migration?
- Are the tracked `backend.tf.migrated.example` files customized before deployment?
- Is `REQUIRE_STATE_STACK_REMOTE=true` required for release and client evidence?

---

### Region Strategy

- What is the primary AWS region?
- Are additional regions required?
- Should CloudTrail be multi-region?
- Are disaster recovery requirements regional or multi-region?

---

### Identity Strategy

- Who administers IAM Identity Center?
- Which users need workload `SecOps-Operator` access?
- Who receives `SecOps-Administrator` access to the security-operations account?
- Will optional `SecOps-Analyst` and `SecOps-Engineer` roles be enabled for workloads or security-operations?
- Who owns break-glass credentials?
- How is break-glass access reviewed?

---

### CI/CD Strategy

- Will GitHub Actions manage Terraform and application image publication?
- Which paired Plan/Apply environments are required?
- Who can approve the protected workload Apply environments?
- Is `DEPLOYMENT_PROFILE` configured in every workload Plan path and synchronized with the intended environment posture?
- Which branches may assume each environment's Image Publisher role through `BRANCHES_IMAGE_PUBLISHER_GITHUB`?
- Is the repository configured to allow GitHub Actions to create release pull requests?
- Are Plan, Apply, and Image Publisher AWS authorities separated by IAM role and trust policy?
- Is the release/PR job kept free of AWS credentials while the publisher job is kept free of repository write permission?
- Will application build contexts reside inside the checked-out repository as required by `Deploy Application`?
- Are release PRs reviewed before merge?
- Will workload Apply use its internally generated saved binary plan rather than the standalone Plan workflow output?
- Are exact saved-plan metadata/checksum checks and protected approvals retained?
- Are application deployment and validation/evidence treated as separate post-merge stages?
- Are static AWS keys prohibited for CI/CD?

### Deployment Profile Strategy

- Which deployment profile should be used for each environment?
- Should `dev` and `staging` use `development` or `production` defaults?
- Should any environment use `minimal`?
- Which profile defaults should be overridden?
- Should AWS Config remain enabled in lower-cost environments?
- Should Backup be enabled outside production?
- Should Inspector be enabled in minimal environments?

---

### Network Strategy

- What VPC CIDR ranges will be used?
- How many Availability Zones are required?
- What outbound internet access is required?
- Which `egress_mode` should each environment use?
- Is AWS Network Firewall required in all environments?
- Is NAT Gateway required in all environments?
- Is `vpc_endpoints_only` acceptable for any environment?
- Which VPC endpoints are required?
- Are dedicated endpoint subnet CIDRs sized appropriately?
- Are any workloads expected to be publicly reachable?

---

### Logging and Monitoring Strategy

- Who receives SecOps alerts?
- Who receives compliance alerts?
- How long should logs be retained?
- Should Object Lock be enabled?
- Which Security Hub CSPM standards and disabled controls should be assigned centrally to each workload?
- Which GuardDuty organization protection plans should be enabled?
- What AWS Config rules are required locally in workload accounts?
- Should findings be exported to an external SIEM?
- Should CloudWatch retention follow deployment profile defaults or explicit overrides?

---

### Incident Response Strategy

- Which environments are authorized for automatic isolation?
- Which severities may trigger automatic containment?
- Which workloads may receive `IsolationAllowed=true`?
- Are quarantine security-group behavior and snapshot permissions validated?
- Who reviews EC2 isolation events and is allowed to trigger rollback?
- Are the SNS notification and rollback paths tested before enabling production isolation?
- What ticketing, approval, and escalation processes apply to containment, tamper alerts, and break-glass use?

---

### Backup and Patch Strategy

- Which resources should be backed up?
- What retention periods are required?
- Should Backup follow deployment profile defaults or explicit overrides?
- What patch windows are acceptable?
- Who reviews patch compliance?
- What recovery testing is required?

---

## Operational Considerations

### Terraform State

Terraform state is sensitive and must be protected.

State buckets are deployed with:

- KMS encryption
- Versioning
- Restricted access
- S3 native lockfiles
- Controlled bucket administration

Each state stack uses a two-phase lifecycle:

1. Apply it locally without an active `backend.tf`.
2. Migrate it into the S3 backend it created with `scripts/bootstrap/migrate-state-stack.sh`.

The repository tracks `backend.tf.migrated.example`, while the active runtime `backend.tf` is ignored by Git and is only created after the backend exists.

Before adopting the baseline for a client or another organization:

- Customize every state-stack backend template for the intended bucket, key, and region.
- Set `EXPECTED_ACCOUNT_ID` during migration.
- Retain the external pre- and post-migration backups.
- Verify the migration with `--verify-only`.
- Require remote-state validation for release evidence.

The existence of `backend.tf` alone is not proof of migration. The remote S3 object and `terraform state pull` must also succeed.

---

### GitHub OIDC Roles

GitHub OIDC roles are critical CI/CD access components. Workload environments use separate Plan and Apply roles, and v1.8.0 adds a dedicated Image Publisher role per workload account.

```text
<env>-plan / Plan role
<env>      / protected Apply role
allowed branch / Image Publisher role
```

The Image Publisher role is deliberately narrow: ECR publication/query authority only, with exact branch-based trust. The `Deploy Application` publisher job must not declare a GitHub Environment because environment-based OIDC subjects differ from the branch-based trust contract.

The release/PR job has the opposite authority boundary: GitHub `contents: write` and `pull-requests: write`, but no AWS credentials and no `id-token`. This prevents a single job from simultaneously holding AWS image-publishing authority and repository mutation authority.

The standalone Terraform Plan workflow and Terraform Apply's internal Plan job are distinct. The protected Apply job consumes only the saved plan produced inside the same Apply workflow run, after checksum/metadata verification.

Current automated workload bootstrap validation proves the Plan/Apply roles and their state/KMS relationships. It does not yet provide equivalent automated proof of the Image Publisher role's branch trust and ECR policy; include those checks in release/client review unless the bootstrap validator is extended later.

Modify workload account stacks carefully and reconcile them when required. Do not destroy account/OIDC stacks before the infrastructure that depends on their roles.

### IAM Identity Center

Identity Center access is centralized from the control plane.

Some optional Identity Center permissions depend on IAM policies created by workload baselines.

This is expected.

The intended pattern is:

```text
1. Configure workload Operator access and required SecOps-Administrator access
2. Deploy workload baselines
3. Confirm workload-created policy names
4. Enable optional Analyst/Engineer roles as needed
5. Re-apply Identity Center
```

The security-operations access model is separate from workload access: `SecOps-Administrator` is required there, `SecOps-Operator` is disabled, and Analyst/Engineer access remains optional.

---

### Deployment Profiles Affect Resource Creation

Deployment profiles and egress modes affect which resources are created.

Examples:

- `production` with `egress_mode = "auto"` deploys Network Firewall and NAT Gateway.
- `development` with `egress_mode = "auto"` deploys NAT Gateway but not Network Firewall.
- `minimal` with `egress_mode = "auto"` does not deploy Network Firewall or NAT Gateway.

Always review the Terraform plan before applying a profile or egress mode change.

---

### Dedicated Endpoint Subnets

Interface VPC Endpoints are deployed into dedicated endpoint private subnets.

These subnets have their own route tables and do not require a default internet route.

Workloads reach Interface Endpoints over VPC-local routing and security group rules.

The endpoint set includes Terraform-managed `guardduty-data`. Compute waits for the Interface Endpoint resources before EC2 launches so GuardDuty Runtime Monitoring can use the existing endpoint instead of creating one outside the Terraform dependency graph.

The S3 Gateway Endpoint is associated with the private route tables that need S3 access.

---

### Destroy Order

Destroy order matters.

Incorrect destroy order can cause:

- IAM policy delete conflicts
- Broken GitHub Actions access
- Orphaned resources
- State backend deletion before dependent stacks are gone

Before teardown, follow the destruction procedure in:

```text
docs/quickstart.md
```

Workload Apply/Destroy automation is intentionally separate from centralized security-services lifecycle. Destroy workload environments before foundational account, security-operations, control-plane, or state stacks.

A state stack must be migrated away from the S3 bucket it manages before that bucket is destroyed. Preserve an external state backup and do not run a self-destructive teardown while the active backend still points to the same bucket.

---

## Cost Considerations

This baseline prioritizes security and visibility for production environments.

Some services can create meaningful cost, especially when deployed across `dev`, `staging`, and `prod`.

Common cost drivers include:

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
- EC2 instances
- RDS instances, if enabled

Deployment profiles and egress modes help make cost/security tradeoffs explicit.

| `deployment_profile` | Cost/security intent |
|---|---|
| `production` | Full baseline for sensitive workloads |
| `development` | Lower-cost development baseline with NAT-only egress |
| `minimal` | Lowest-cost AWS-private testing profile |

| `egress_mode` | Cost/security intent |
|---|---|
| `network_firewall` | Highest egress control, highest network inspection cost |
| `nat_only` | Lower-cost internet egress without Network Firewall |
| `vpc_endpoints_only` | Lowest egress cost, no general internet route |

Teams should review cost expectations before deploying all environments.

Recommended adoption pattern:

- Deploy and validate `dev` first
- Review cost
- Deploy `staging`
- Review cost again
- Deploy `prod`

---

## Security Review Checklist Before Production Use

Before using this baseline for production workloads, confirm:

- Required AWS accounts exist and are controlled.
- Terraform state resources are protected.
- Every state stack has been migrated and passes `migrate-state-stack.sh --verify-only`.
- Release evidence requires remotely readable state stacks.
- GitHub OIDC Plan, Apply, and Image Publisher roles are working, with the publisher role restricted to approved branches and ECR publication/query authority.
- GitHub Actions is permitted to create release PRs if `Deploy Application` automation is used.
- A registered-but-unreleased ECS service can retain its ECR repository with `image_digest = null` without creating runtime resources.
- The application release path has been proven through image publication, authoritative digest resolution, one-field release PR, protected exact-plan Apply, ECS steady state, and workload validation.
- GitHub environments have appropriate protections.
- IAM Identity Center groups are assigned correctly.
- Break-glass access is documented and tested.
- CloudTrail is logging.
- The security-operations account is the expected Security Hub and GuardDuty delegated administrator.
- Security Hub CSPM central policies are associated successfully with intended workload accounts.
- GuardDuty organization features and Runtime Monitoring match the approved configuration.
- Security Hub V2 policy is attached to `Workloads` and resolves correctly for workload accounts.
- AWS Config is recording in workload accounts where expected.
- SNS subscriptions are confirmed.
- EC2 isolation and rollback tests pass.
- Production automatic isolation remains disabled unless it has been explicitly approved and tested.
- Snapshot creation, quarantine networking, SNS notification, and rollback permissions are validated.
- IP enrichment tests pass.
- Backup resources are configured.
- Patch management settings are reviewed.
- Production uses the expected deployment profile.
- Production uses the expected egress mode.
- Network Firewall routing is active if required.
- VPC endpoint coverage is sufficient for private AWS service access.
- Dedicated endpoint subnets are deployed and validated.
- `guardduty-data` is Terraform-managed and deployed before workload EC2.
- Cost estimates are understood.
- Destroy procedure is understood.

---

## How to Extend the Baseline

Common extension areas include:

- Adding Service Control Policies
- Expanding centralized security governance to additional services or Regions
- Adding external SIEM forwarding
- Adding additional AWS Config rules
- Adding additional VPC endpoint services
- Adding additional Lambda responders
- Adding ECS task-role capabilities through reviewed typed interfaces
- Adding support for alternative CI/CD providers
- Adding more granular Identity Center roles
- Adding Kubernetes or other workload patterns beyond the supported EC2 and ECS/Fargate runtimes
- Adding multi-region disaster recovery patterns
- Adding additional deployment profiles or profile-controlled services
- Adding additional egress modes or proxy-based egress support

Extensions should preserve the core design principles:

- Keep control-plane resources separate
- Keep state isolated
- Avoid circular dependencies
- Prefer least privilege
- Preserve logging and detection integrity
- Avoid introducing long-lived CI/CD credentials
- Keep cost/security tradeoffs explicit
- Keep private AWS service access scoped through VPC endpoints where practical

---

## Summary

`tf-secure-baseline` is appropriate for teams that need a secure, repeatable AWS foundation for sensitive workloads.

It provides a strong starting point for:

- Multi-account AWS structure
- Secure CI/CD access
- Centralized identity
- Delegated security administration
- Private networking
- Configurable deployment profiles
- Configurable egress behavior
- Dedicated VPC endpoint subnets
- Logging and monitoring
- Event-driven incident response
- Audit-readiness

It should be adopted thoughtfully, validated carefully, and customized to match the organization’s operational and security requirements.