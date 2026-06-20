# tf-secure-baseline Validation Report Template

## Purpose

This template provides a client-facing or internal handoff format for documenting validation results from a deployed `tf-secure-baseline` workload environment.

It is intended to summarize:

- Which environment was validated
- When validation was performed
- Which automated validation checks passed or failed
- Which evidence files were generated
- Which manual validation activities remain
- Any warnings, exceptions, or limitations

This template can be completed manually, or used as a reference for generated validation reports produced by `scripts/validation/export-report.sh`.

---

## Client / Project

| Field | Value |
|---|---|
| Client / Organization | `<client-name>` |
| Project / Engagement | `<project-name>` |
| Prepared By | `<name>` |
| Prepared Date | `<YYYY-MM-DD>` |
| Report Version | `<version>` |

---

## Environment

| Field | Value |
|---|---|
| Environment | `<dev/staging/prod>` |
| AWS Account ID | `<account-id>` |
| AWS Region | `<region>` |
| Name Prefix | `<name-prefix>` |
| Deployment Profile | `<production/development/minimal>` |
| Egress Mode | `<network_firewall/nat_only/vpc_endpoints_only/auto>` |
| Effective Egress Mode | `<resolved-egress-mode>` |
| Validation Time | `<timestamp>` |

---

## Executive Summary

| Field | Value |
|---|---|
| Overall Result | `<PASS/FAIL>` |
| Validation Scripts Passed | `<passed>/<total>` |
| Validation Scripts Failed | `<failed>/<total>` |
| Report Package Location | `<path-or-reference>` |

Summary:

`<Briefly summarize the result of the validation run. Example: The dev workload environment completed automated read-only validation with 14 of 14 validation scripts passing. Manual validation activities remain for live workflow tests, control-plane checks, and operational sign-off.>`

---

## Automated Validation Results

| Area | Script | Result | Evidence Log | Notes |
|---|---|---|---|---|
| Environment | `validate-env.sh` | `<PASS/FAIL>` | `validate-env.log` | `<notes>` |
| Networking | `validate-networking.sh` | `<PASS/FAIL>` | `validate-networking.log` | `<notes>` |
| VPC Endpoints | `validate-vpc-endpoints.sh` | `<PASS/FAIL>` | `validate-vpc-endpoints.log` | `<notes>` |
| Logging | `validate-logging.sh` | `<PASS/FAIL>` | `validate-logging.log` | `<notes>` |
| Security Services | `validate-security-services.sh` | `<PASS/FAIL>` | `validate-security-services.log` | `<notes>` |
| KMS | `validate-kms.sh` | `<PASS/FAIL>` | `validate-kms.log` | `<notes>` |
| Backup | `validate-backup.sh` | `<PASS/FAIL>` | `validate-backup.log` | `<notes>` |
| SNS | `validate-sns.sh` | `<PASS/FAIL>` | `validate-sns.log` | `<notes>` |
| SQS | `validate-sqs.sh` | `<PASS/FAIL>` | `validate-sqs.log` | `<notes>` |
| EventBridge | `validate-eventbridge.sh` | `<PASS/FAIL>` | `validate-eventbridge.log` | `<notes>` |
| Lambda | `validate-lambda.sh` | `<PASS/FAIL>` | `validate-lambda.log` | `<notes>` |
| SSM | `validate-ssm.sh` | `<PASS/FAIL>` | `validate-ssm.log` | `<notes>` |
| Compute | `validate-compute.sh` | `<PASS/FAIL>` | `validate-compute.log` | `<notes>` |
| IAM | `validate-iam.sh` | `<PASS/FAIL>` | `validate-iam.log` | `<notes>` |

---

## Manual Validation Results

The automated validation suite is intentionally read-only. The following items should be reviewed manually where applicable.

| Manual Check | Status | Evidence / Notes |
|---|---|---|
| Control-plane resource validation | `<Not Started/In Progress/Complete/Not Applicable>` | `<notes>` |
| IAM Identity Center assignment validation | `<Not Started/In Progress/Complete/Not Applicable>` | `<notes>` |
| GitHub Actions workflow validation | `<Not Started/In Progress/Complete/Not Applicable>` | `<notes>` |
| Live EC2 isolation test | `<Not Started/In Progress/Complete/Not Applicable>` | `<notes>` |
| Live EC2 rollback test | `<Not Started/In Progress/Complete/Not Applicable>` | `<notes>` |
| Live IP enrichment test | `<Not Started/In Progress/Complete/Not Applicable>` | `<notes>` |
| Tamper detection test | `<Not Started/In Progress/Complete/Not Applicable>` | `<notes>` |
| Break-glass role assumption test | `<Not Started/In Progress/Complete/Not Applicable>` | `<notes>` |
| Destroy safety review | `<Not Started/In Progress/Complete/Not Applicable>` | `<notes>` |

---

## Warnings / Exceptions

Document any warnings, expected deviations, skipped checks, or environment-specific exceptions.

| Item | Severity | Description | Disposition |
|---|---|---|---|
| `<item>` | `<Low/Medium/High>` | `<description>` | `<accepted/remediated/deferred/not applicable>` |

Examples of acceptable environment-specific exceptions may include:

- Backup resources not required when `effective_backup_enabled = false`
- Network Firewall not required when `effective_egress_mode = nat_only`
- Network Firewall and NAT Gateway not required when `effective_egress_mode = vpc_endpoints_only`
- AWS Config rules not required when Config is intentionally disabled by deployment profile
- Pending SNS email confirmation where subscriber approval is still required

---

## Evidence Files

| File | Purpose |
|---|---|
| `summary.md` | Human-readable validation report |
| `summary.json` | Machine-readable validation summary |
| `validate-env.log` | Environment and Terraform output validation |
| `validate-networking.log` | VPC, subnet, NAT, firewall, and route validation |
| `validate-vpc-endpoints.log` | VPC endpoint placement and route validation |
| `validate-logging.log` | CloudTrail, VPC Flow Logs, CloudWatch, alarms, and retention validation |
| `validate-security-services.log` | GuardDuty, Security Hub, AWS Config, Inspector, and related service validation |
| `validate-kms.log` | KMS key and alias validation |
| `validate-backup.log` | AWS Backup validation |
| `validate-sns.log` | SNS topic, subscription, and encryption validation |
| `validate-sqs.log` | SQS queue, policy, DLQ, and encryption validation |
| `validate-eventbridge.log` | EventBridge bus, rule, and target validation |
| `validate-lambda.log` | Lambda function, runtime, role, VPC, KMS, and permission validation |
| `validate-ssm.log` | SSM managed instance, maintenance window, and patch baseline validation |
| `validate-compute.log` | EC2 placement, tags, IMDSv2, EBS encryption, and instance profile validation |
| `validate-iam.log` | IAM role, trust policy, OIDC role, break-glass, and shared policy validation |

---

## Limitations

This report validates deployed AWS control presence and selected configuration settings for the target workload environment.

The validation suite confirms the presence and configuration of selected AWS security controls in the deployed environment.

This report does not replace:

- A full SOC 2 audit
- A full ISO 27001 audit
- Control owner review
- Policy and procedure review
- Control design assessment
- Control operating effectiveness testing
- Formal audit evidence review
- Risk assessment
- Vendor risk review
- Incident response testing
- Business continuity or disaster recovery testing
- A complete Information Security Management System

---

## Sign-Off

| Role | Name | Date | Notes |
|---|---|---|---|
| Technical Reviewer | `<name>` | `<date>` | `<notes>` |
| Security Reviewer | `<name>` | `<date>` | `<notes>` |
| Client / Stakeholder | `<name>` | `<date>` | `<notes>` |