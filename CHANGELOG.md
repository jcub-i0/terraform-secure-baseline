# Changelog

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