# Changelog

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