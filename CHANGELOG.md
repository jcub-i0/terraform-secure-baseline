# Changelog

## v1.4.2

### Added

- Added `scripts/bootstrap/reconcile-workload-account.sh` to resolve current
  workload Lambda and Secrets Manager CMK outputs, safely reconcile them into
  the workload GitHub Apply role, and run strict post-apply bootstrap
  validation.

### Changed

- Updated deployment and validation guidance to use
  `scripts/bootstrap/reconcile-workload-account.sh <env>` instead of manually
  copying workload CMK outputs and re-applying `bootstrap/<env>/account`.

## v1.4.1

### Changed

- Replaced tracked runtime `terraform.tfvars` files with
  `terraform.tfvars.example` templates.
- Updated GitHub Actions to provide required Terraform values through workflow
  matrices, GitHub variables, and secrets.
- Updated onboarding instructions for creating ignored local variable files.

### Security

- Added Git ignore coverage for runtime Terraform variable files to reduce the
  risk of committing client-specific or sensitive configuration.

## v1.4.0

This release improves client-readiness and operational safety by adding layer-specific validation evidence exports, migrating bootstrap state stacks to protected remote S3 backends, and adding GitHub Actions workflows for repeatable validation evidence collection.

### Added

- Added workload bootstrap evidence export through `scripts/validation/export-bootstrap.sh`.
- Added control-plane evidence export through `scripts/validation/export-control-plane.sh`.
- Added timestamped workload bootstrap evidence packages under `validation-results/<environment>/bootstrap/<timestamp>/`.
- Added timestamped control-plane evidence packages under `validation-results/control-plane/<timestamp>/`.
- Added `scripts/bootstrap/migrate-state-stack.sh` for guarded migration of workload and control-plane state stacks from initial local state to their own S3 backends.
- Added `scripts/bootstrap/README.md` documenting state-stack migration, verification, repository behavior, and safety expectations.
- Added tracked post-migration backend templates named `backend.tf.migrated.example` for workload and control-plane state stacks.
- Added strict remote state-stack validation through `REQUIRE_STATE_STACK_REMOTE`.
- Added validation coverage for active state-stack S3 backends, shared backend bucket and region consistency, distinct state object keys, migrated state object readability, successful `terraform state pull`, and state bucket output consistency.
- Added manual GitHub Actions evidence workflows for workload bootstrap, workload baseline, and control-plane validation.
- Added GitHub Actions artifact upload behavior for generated validation evidence packages.
- Added runtime materialization of ignored state-stack `backend.tf` files from tracked `backend.tf.migrated.example` templates during evidence workflows.

### Changed

- Renamed `scripts/validation/export-all.sh` to `scripts/validation/export-baseline.sh`.
- Standardized validation evidence around three layers:
  - workload bootstrap;
  - workload baseline;
  - control plane.
- Changed state stacks from long-lived local state to a two-phase lifecycle:
  - initial local initialization and apply;
  - guarded migration into encrypted remote S3 state with native lockfiles.
- Changed state-stack backend handling so active `bootstrap/*/state/backend.tf` files are ignored by Git while post-migration templates remain tracked.
- Updated workload bootstrap and control-plane validators to support strict or advisory remote state-stack checks.
- Updated evidence workflows to initialize state, account, workload, organizations, and Identity Center Terraform roots before validation where applicable.
- Updated validation documentation, architecture documentation, design principles, quickstart guidance, adoption guidance, root README, and validation checklist to describe the remote state-stack lifecycle and evidence workflows.
- Updated workload baseline evidence output paths to `validation-results/<environment>/baseline/<timestamp>/`.
- Updated deployment and validation guidance to use `scripts/bootstrap/migrate-state-stack.sh <target>` after the initial state-stack apply.
- Updated teardown guidance to account for state stacks whose Terraform state is stored in the S3 bucket they manage.

### Removed

- Removed the long-lived local-state expectation for workload and control-plane state stacks.
- Removed obsolete guidance that treated the absence of `bootstrap/<target>/state/backend.tf` as the expected post-deployment state.
- Removed stale DynamoDB state-locking references from current deployment and validation guidance.
- Removed obsolete lock-table output and GitHub environment variable references from the quickstart.

### Notes

State stacks still require an initial local apply because they create their own backend resources. After that apply, `scripts/bootstrap/migrate-state-stack.sh` validates the selected AWS account and backend template, creates external backups, refuses to overwrite an existing remote state object, runs interactive `terraform init -migrate-state`, and verifies the resulting S3 state object with `terraform state pull`.

The active state-stack `backend.tf` files are intentionally ignored by Git. The tracked `backend.tf.migrated.example` files define the intended post-migration configuration and are also used by GitHub evidence workflows to materialize the runtime backend before initialization.

Direct validation script runs default `REQUIRE_STATE_STACK_REMOTE` to `false` so transitional findings can remain advisory. The GitHub workload bootstrap and control-plane evidence workflows default remote state-stack validation to strict behavior.

Generated validation evidence remains ignored by Git and does not replace live GitHub Actions execution testing, IAM Identity Center end-user access testing, Lambda workflow tests, tamper tests, break-glass tests, or destroy safety review.

## v1.3.4

This release completes the validation architecture cleanup by organizing validation into workload bootstrap, workload baseline, and control-plane validation layers while standardizing Terraform state-locking validation around S3 native lockfiles.

### Added

- Added automated workload bootstrap validation with `scripts/validation/validate-bootstrap.sh`.
- Added automated read-only control-plane validation with `scripts/validation/validate-control-plane.sh`.
- Added validation coverage for workload bootstrap directory structure, backend lockfile configuration, state bucket security, state CMK configuration, GitHub OIDC roles, and GitHub role access to Terraform state resources.
- Added control-plane validation coverage for state backend resources, GitHub OIDC roles, AWS Organizations OU structure, IAM Identity Center basics, optional account assignments, and expected GitHub repository trust conditions.
- Added CI-safe bootstrap validation behavior that does not require local `terraform.tfstate` from `bootstrap/<env>/state`.
- Added backend-file-based state bucket resolution for workload bootstrap validation.
- Added live S3 and KMS validation for Terraform state bucket versioning, public access block, SSE-KMS encryption, and customer-managed state CMK status.
- Added validation that workload and control-plane remote backends use Terraform S3 native locking with `use_lockfile = true`.
- Added `scripts/validation/README.md` to document validation layers, usage, safety boundaries, troubleshooting, and recommended validation order.

### Changed

- Renamed `scripts/validation/validate-all.sh` to `scripts/validation/validate-baseline.sh`.
- Preserved `scripts/validation/validate-all.sh` as a deprecated compatibility wrapper for `validate-baseline.sh`.
- Updated validation documentation to distinguish workload bootstrap validation, workload baseline validation, control-plane validation, and manual live workflow testing.
- Updated root-level README validation guidance to describe all three validation layers.
- Updated `docs/validation-checklist.md` to reflect CI-safe bootstrap validation, control-plane validation, and S3 native lockfile behavior.
- Changed bootstrap validation to treat remote backend files as the source of truth for state bucket location, backend region, state object keys, and `use_lockfile = true`.
- Changed bootstrap validation to resolve the state CMK from the live S3 bucket encryption configuration instead of relying on local bootstrap state outputs.
- Standardized validation language around Terraform S3 native locking with `use_lockfile = true`.

### Removed

- Removed stale DynamoDB state-locking expectations from validation guidance.
- Removed the bootstrap validator's dependency on local Terraform outputs from `bootstrap/<env>/state`.
- Removed local `terraform.tfstate` presence checks from workload bootstrap validation.

### Notes

DynamoDB state locking is not expected because this project uses Terraform S3 native locking with `use_lockfile = true`; DynamoDB-based locking for the S3 backend is deprecated.

`validate-bootstrap.sh` remains read-only. It does not run `terraform init`, `terraform apply`, `terraform destroy`, backend migration, role assumption, or live workflow execution. For fresh checkouts or manual GitHub workflow runs, initialize the remote-backed account and workload stacks before running bootstrap validation so Terraform outputs can be read from the S3 backend.

`validate-control-plane.sh` remains read-only. It validates control-plane state backend resources, GitHub OIDC roles, AWS Organizations structure, IAM Identity Center basics, and optional account assignment evidence, but it does not execute GitHub workflows, move accounts between OUs, modify Identity Center assignments, assume privileged roles, or perform destructive operations.

## v1.3.3

### Added

- Added `scripts/validation/validate-control-plane.sh` for safe, read-only control-plane validation.
- Added validation coverage for control-plane Terraform state backend resources.
- Added validation coverage for control-plane GitHub OIDC provider and plan/apply roles.
- Added validation coverage for AWS Organizations OU structure.
- Added validation coverage for IAM Identity Center instance, SecOps groups, permission sets, and account assignments.

### Changed

- Updated validation checklist to make automated control-plane validation the preferred path.
- Clarified that manual validation is still required for GitHub Actions execution, end-user SSO testing, live Lambda tests, tamper tests, break-glass tests, and destroy safety review.

### Notes

- AWS Organizations account placement warnings are treated as warnings unless account placement is explicitly managed by Terraform.

## v1.3.2

### Fixed

- Fixed AWS Network Firewall resource naming so the firewall name includes the environment-specific name prefix.
- Fixed networking validation to match the exact expected Network Firewall name instead of using broad prefix containment.
- Fixed networking validation for Network Firewall routes where AWS may expose firewall endpoint targets through `GatewayId` instead of `VpcEndpointId`.

### Changed

- Added `create_before_destroy` lifecycle behavior to the Network Firewall resource to support safer forced replacements during firewall renames.
- Enhanced networking validation to normalize route targets into consistent target types such as VPC endpoint, NAT Gateway, Internet Gateway, local route, transit gateway, and network interface.
- Expanded networking validation for `network_firewall` mode to validate the full inspected egress path:
  - compute private route tables route default traffic to firewall VPC endpoints;
  - firewall private route tables route default traffic to NAT Gateways;
  - public route tables route default traffic to Internet Gateways;
  - public route tables return compute private subnet CIDRs through firewall VPC endpoints.

## v1.3.1

### Added

- Added a dedicated security notifications SQS queue subscribed to the security notifications SNS topic.
- Added a security notifications SQS DLQ for repeatedly unprocessed security notification messages.
- Added a shared security notifications EventBridge DLQ for failed EventBridge deliveries to the security notifications SNS topic.
- Added a CloudWatch alarm for visible messages in the security notifications EventBridge DLQ.
- Added workflow-specific DLQs for EC2 Isolation, EC2 Rollback, and IP Enrichment automation workflows.
- Added EventBridge target DLQ configuration and retry policies for protected automation and security notification targets.
- Added Lambda asynchronous failure handling for the EC2 Isolation, EC2 Rollback, and IP Enrichment workflows.
- Added CloudWatch DLQ alarms for security automation failure paths.
- Added notification and DLQ validation guidance to `docs/validation-checklist.md`.
- Added DLQ triage and safe message inspection guidance to `docs/validation-checklist.md`.

### Changed

- Updated security notification routing to support both human alert delivery and durable SQS-backed message retention.
- Updated EventBridge security notification targets to use retry policies and a shared EventBridge DLQ.
- Updated automation workflows so EventBridge delivery failures are retained in workflow-specific DLQs.
- Updated SQS validation to include compliance, security notification, security notification DLQ, security notification EventBridge DLQ, and security automation DLQ resources.
- Updated EventBridge validation to verify target DLQs, retry policies, expected target ARNs, and expected DLQ ARNs.
- Updated monitoring, automation, security, tamper detection, and root-level documentation to reflect the new notification and DLQ architecture.
- Condensed the monitoring module README and moved detailed notification/DLQ validation and response guidance into `docs/validation-checklist.md`.

### Notes

- Workflow DLQs are terminal failure-retention queues intended for SecOps review, troubleshooting, and manual replay or remediation where appropriate.
- The security notifications EventBridge DLQ covers EventBridge-to-SNS delivery failures.
- The security notifications SQS DLQ covers repeated processing failures after messages have already reached the security notifications SQS queue.
- The compliance and security notification queues may accumulate visible messages when no downstream consumer is configured. This is expected when the queues are used as durable notification subscribers.
- The new DLQ hardening improves alert-delivery resilience but does not automatically replay failed security automation or notification events.

## v1.3.0

### Added

- Added validation report export workflow through `scripts/validation/export-baseline.sh`.
- Added timestamped validation result directories under `validation-results/<environment>/<timestamp>/`.
- Added per-script validation log capture.
- Added generated Markdown validation summaries through `summary.md`.
- Added generated machine-readable validation summaries through `summary.json`.
- Added validation report template under `docs/assurance/validation-report-template.md`.
- Added validation evidence guide under `docs/assurance/validation-evidence-guide.md`.

### Changed

- Updated validation documentation to describe exported validation evidence packages.
- Updated project documentation to position validation reports for client handoff, troubleshooting, and deployment evidence.

### Notes

- Generated validation output is ignored by Git by default.
- Validation reporting is intended to support deployment evidence and audit-readiness discussions.
- Validation reports do not replace formal SOC 2 or ISO 27001 audits, control owner review, policy review, risk assessment, or ISMS activities.

## v1.2.1

### Fixed

- Fixed Amazon Inspector enablement wiring so the security module respects the resolved `effective_inspector_enabled` value.
- Updated Inspector validation to check the effective Inspector resource types instead of assuming EC2, Lambda, and Lambda code scanning are all enabled.
- Removed unnecessary Amazon Inspector access from the Lambda KMS key policy.

### Changed

- Added configurable `inspector_resource_types` support.
- Defaulted Amazon Inspector resource types to EC2 scanning only.
- Disabled Lambda and Lambda code scanning by default because the baseline uses customer-managed KMS encryption for Lambda resources.
- Updated security module documentation to reflect configurable Inspector behavior and Lambda CMK policy changes.

## v1.2.0

### Added

- Added a safe, read-only post-deployment validation suite for workload environments.
- Added `validate-all.sh` as the primary validation entry point for `dev`, `staging`, and `prod`.
- Added workload validation scripts for:
  - Environment outputs and account identity
  - Networking and controlled egress
  - VPC endpoints
  - Logging
  - Security services
  - KMS
  - AWS Backup
  - SNS
  - SQS
  - EventBridge
  - Lambda
  - SSM
  - Compute
  - IAM
- Added expected AWS account validation through `EXPECTED_ACCOUNT_ID`.
- Added profile-aware validation behavior for AWS Config, AWS Backup, Inspector, and effective egress mode.
- Added validation coverage for SNS-to-SQS delivery paths, queue policies, queue encryption, visible messages, and not-visible messages.
- Added validation coverage for Lambda runtime, state, execution role, timeout, memory, KMS configuration, VPC configuration, environment variables, resource policies, and EventBridge permissions.
- Added validation coverage for EC2 compute instance placement, public IP absence, IMDSv2 enforcement, detailed monitoring, instance profiles, security groups, required tags, isolation eligibility, and EBS encryption.
- Added validation coverage for Backup vaults, plans, selections, schedules, retention, tagged resources, recent jobs, and recovery point reporting.

### Changed

- Updated `docs/validation-checklist.md` to make automated workload validation the default validation path.
- Updated validation guidance to distinguish safe read-only checks from live workflow tests, tamper tests, break-glass tests, and destroy safety checks.
- Improved validation summary output across SNS, SQS, KMS, Backup, Lambda, SSM, Compute, and related scripts.
- Improved validation output readability by shortening long resource names, ARNs, and table columns where appropriate.
- Updated root-level documentation to include the validation suite and v1.2.0 release highlights.

### Notes

- The automated validation suite is intentionally read-only and does not perform live isolation, rollback, tamper, break-glass, GitHub Actions, Identity Center, or destroy workflow tests.
- Live workflow validation remains manual and should only be run in approved environments.
- A successful full workload validation run should report `14/14` validation scripts passed.

## v1.1.1

### Changed
- Refactored IAM, SNS topic, EventBridge bus, and S3 bucket policies to use `aws_iam_policy_document` data sources instead of inline `jsonencode()` policy documents.
- Improved policy readability, consistency, and maintainability across IAM roles, managed policies, inline policies, trust policies, and resource-based policies.
- Removed redundant Lambda principals from the SecOps SNS topic policy, relying instead on Lambda execution role permissions for direct SNS publishing.
- Added stronger bucket policy protections for state and centralized logging buckets using explicit deny controls and admin-principal exceptions.

## v1.1.0

### Added

- Added deployment profiles for `production`, `development`, and `minimal`.
- Added configurable egress modes:
  - `network_firewall`
  - `nat_only`
  - `vpc_endpoints_only`
- Added dedicated private subnets for Interface VPC Endpoints.
- Added profile-aware defaults for AWS Config, AWS Backup, Inspector, and CloudWatch Logs retention.
- Added effective Terraform outputs for deployment profile and resolved feature settings.
- Added documentation validation workflow.
- Improved Terraform static analysis workflow coverage.

### Changed

- Network Firewall is now deployed only when required by the effective egress mode.
- NAT Gateways are now deployed only when required by the effective egress mode.
- Interface VPC Endpoints now deploy into dedicated endpoint private subnets.
- S3 Gateway Endpoint route table behavior is now explicitly controlled by the baseline stack.
- IAM module policies were refactored from inline `jsonencode()` policy JSON to `aws_iam_policy_document` data sources.
- Documentation updated for deployment profiles, egress modes, and dedicated VPC endpoint subnets.

### Notes

- `production` defaults to `network_firewall`.
- `development` defaults to `nat_only`.
- `minimal` defaults to `vpc_endpoints_only`, with no NAT Gateway, no Network Firewall, and no general internet route for compute private subnets.

## v1.0.0

### Added

- Added initial stable release of `tf-secure-baseline`.
- Added multi-account environment structure for:
  - `dev`
  - `staging`
  - `prod`
  - `control-plane`
- Added Terraform remote state bootstrap pattern using S3, DynamoDB, and KMS.
- Added GitHub Actions OIDC federation for plan/apply workflows.
- Added IAM Identity Center integration for centralized human access.
- Added private-first VPC architecture with segmented subnet tiers.
- Added AWS Network Firewall-based egress inspection.
- Added VPC endpoints for private AWS service access.
- Added centralized CloudTrail, AWS Config, VPC Flow Logs, and CloudWatch logging.
- Added GuardDuty, Security Hub, Inspector, and AWS Config baseline controls.
- Added EventBridge-driven security automation.
- Added EC2 isolation and rollback workflows.
- Added IP threat intelligence enrichment workflow.
- Added tamper detection for critical security services.
- Added break-glass role monitoring.
- Added KMS-backed encryption across logs, Lambda, EBS, Secrets Manager, and backups.
- Added AWS Backup and SSM Patch Manager support.
- Added completed system-level documentation and module README files.

### Documentation

- Added quickstart guide.
- Added architecture overview.
- Added design principles.
- Added adoption guide.
- Added validation checklist.
- Added SOC 2 control mapping.
- Added ISO 27001 control mapping.
- Added control narratives.
- Added Lambda test documentation.
- Added module-level README files.

### Notes

- This baseline supports SOC 2 and ISO 27001 readiness, but does not replace a complete compliance program, ISMS, formal risk management process, or audit.
- AWS Network Firewall, NAT Gateway, VPC endpoints, CloudWatch Logs, GuardDuty, Security Hub, Inspector, and Backup may generate ongoing AWS costs.
- Production deployments should review deletion protection, Object Lock, retention periods, KMS `prevent_destroy`, and environment-specific access controls before use.