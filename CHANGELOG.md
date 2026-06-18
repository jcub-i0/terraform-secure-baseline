# Changelog

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