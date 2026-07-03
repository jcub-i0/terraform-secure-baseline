# tf-secure-baseline Validation Report Template

## Purpose

This template provides a client-facing or internal handoff format for documenting validation results from a deployed `tf-secure-baseline` workload environment and, where applicable, the supporting control plane.

It is intended to summarize:

- Which environment or validation scope was validated
- When validation was performed
- Which automated workload validation checks passed or failed
- Which automated control-plane validation checks passed, warned, or failed
- Which evidence files were generated
- Which manual validation activities remain
- Any warnings, exceptions, or limitations

This template can be completed manually, used as a reference for generated workload validation reports produced by `scripts/validation/export-report.sh`, or used to summarize a separate control-plane validation run from `scripts/validation/validate-control-plane.sh`.

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

## Validation Scope

| Field | Value |
|---|---|
| Scope | `<workload/control-plane/combined>` |
| Environment | `<dev/staging/prod/control-plane>` |
| AWS Account ID | `<account-id>` |
| AWS Region | `<region>` |
| Name Prefix | `<name-prefix>` |
| Deployment Profile | `<production/development/minimal/not-applicable>` |
| Egress Mode | `<network_firewall/nat_only/vpc_endpoints_only/auto/not-applicable>` |
| Effective Egress Mode | `<resolved-egress-mode/not-applicable>` |
| Validation Time | `<timestamp>` |
| Report Package Location | `<path-or-reference>` |

For workload validation, complete the deployment profile and egress-mode fields.

For control-plane validation, use `not-applicable` for workload-only fields such as deployment profile and effective egress mode.

---

## Executive Summary

| Field | Value |
|---|---|
| Overall Result | `<PASS/WARN/FAIL>` |
| Workload Validation Scripts Passed | `<passed>/<total>` |
| Workload Validation Scripts Failed | `<failed>/<total>` |
| Control-Plane Validation Result | `<PASS/WARN/FAIL/Not Run/Not Applicable>` |
| Manual Validation Remaining | `<yes/no>` |

Summary:

`<Briefly summarize the validation outcome. Example: The dev workload environment completed automated read-only validation with 14 of 14 validation scripts passing. The control plane also passed automated read-only validation for state backend resources, GitHub OIDC, AWS Organizations OU structure, and IAM Identity Center basics. Manual validation remains for GitHub Actions execution, end-user SSO access, live Lambda workflow tests, tamper testing, break-glass testing, and destroy safety review.>`

---

## Automated Workload Validation Results

Use this section for workload environments such as `dev`, `staging`, and `prod`.

| Area | Script | Result | Evidence Log | Notes |
|---|---|---|---|---|
| Environment | `validate-env.sh` | `<PASS/FAIL/Not Run>` | `validate-env.log` | `<notes>` |
| Networking | `validate-networking.sh` | `<PASS/FAIL/Not Run>` | `validate-networking.log` | `<notes>` |
| VPC Endpoints | `validate-vpc-endpoints.sh` | `<PASS/FAIL/Not Run>` | `validate-vpc-endpoints.log` | `<notes>` |
| Logging | `validate-logging.sh` | `<PASS/FAIL/Not Run>` | `validate-logging.log` | `<notes>` |
| Security Services | `validate-security-services.sh` | `<PASS/FAIL/Not Run>` | `validate-security-services.log` | `<notes>` |
| KMS | `validate-kms.sh` | `<PASS/FAIL/Not Run>` | `validate-kms.log` | `<notes>` |
| Backup | `validate-backup.sh` | `<PASS/FAIL/Not Run>` | `validate-backup.log` | `<notes>` |
| SNS | `validate-sns.sh` | `<PASS/FAIL/Not Run>` | `validate-sns.log` | `<notes>` |
| SQS | `validate-sqs.sh` | `<PASS/FAIL/Not Run>` | `validate-sqs.log` | `<notes>` |
| EventBridge | `validate-eventbridge.sh` | `<PASS/FAIL/Not Run>` | `validate-eventbridge.log` | `<notes>` |
| Lambda | `validate-lambda.sh` | `<PASS/FAIL/Not Run>` | `validate-lambda.log` | `<notes>` |
| SSM | `validate-ssm.sh` | `<PASS/FAIL/Not Run>` | `validate-ssm.log` | `<notes>` |
| Compute | `validate-compute.sh` | `<PASS/FAIL/Not Run>` | `validate-compute.log` | `<notes>` |
| IAM | `validate-iam.sh` | `<PASS/FAIL/Not Run>` | `validate-iam.log` | `<notes>` |

Expected successful workload validation summary:

```text
Validation scripts passed:  14/14
Validation scripts failed:  0/14
```

---

## Automated Control-Plane Validation Results

Use this section for the `control-plane` account.

Run the control-plane validation script separately from workload validation:

```bash
AWS_PAGER="" \
AWS_PROFILE=control-plane \
AWS_REGION="<region>" \
EXPECTED_ACCOUNT_ID="<CONTROL-PLANE-ACCOUNT-ID>" \
EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" \
ACCOUNT_ID_DEV="<DEV-ACCOUNT-ID>" \
ACCOUNT_ID_STAGING="<STAGING-ACCOUNT-ID>" \
ACCOUNT_ID_PROD="<PROD-ACCOUNT-ID>" \
./scripts/validation/validate-control-plane.sh
```

| Area | Result | Evidence Log | Notes |
|---|---|---|---|
| AWS caller identity and expected account ID | `<PASS/WARN/FAIL/Not Run>` | `validate-control-plane.log` | `<notes>` |
| Control-plane Terraform state stack outputs | `<PASS/WARN/FAIL/Not Run>` | `validate-control-plane.log` | `<notes>` |
| Terraform state S3 bucket existence, versioning, encryption, and public access block | `<PASS/WARN/FAIL/Not Run>` | `validate-control-plane.log` | `<notes>` |
| Terraform state KMS CMK existence and key state | `<PASS/WARN/FAIL/Not Run>` | `validate-control-plane.log` | `<notes>` |
| Terraform state DynamoDB lock table existence and status | `<PASS/WARN/FAIL/Not Run>` | `validate-control-plane.log` | `<notes>` |
| GitHub OIDC provider existence | `<PASS/WARN/FAIL/Not Run>` | `validate-control-plane.log` | `<notes>` |
| Control-plane GitHub plan/apply role existence | `<PASS/WARN/FAIL/Not Run>` | `validate-control-plane.log` | `<notes>` |
| GitHub OIDC trust policy conditions for expected repository | `<PASS/WARN/FAIL/Not Run>` | `validate-control-plane.log` | `<notes>` |
| AWS Organizations root and OU structure | `<PASS/WARN/FAIL/Not Run>` | `validate-control-plane.log` | `<notes>` |
| Workload account OU placement | `<PASS/WARN/FAIL/Not Run>` | `validate-control-plane.log` | `<notes>` |
| IAM Identity Center instance discovery | `<PASS/WARN/FAIL/Not Run>` | `validate-control-plane.log` | `<notes>` |
| SecOps Identity Center group existence | `<PASS/WARN/FAIL/Not Run>` | `validate-control-plane.log` | `<notes>` |
| Identity Center permission set outputs and existence | `<PASS/WARN/FAIL/Not Run>` | `validate-control-plane.log` | `<notes>` |
| Identity Center account assignment presence | `<PASS/WARN/FAIL/Not Run>` | `validate-control-plane.log` | `<notes>` |

Expected successful control-plane validation summary:

```text
[PASS] Control-plane validation completed successfully
```

### Control-Plane Warning Notes

Document any warnings from the control-plane validation script.

Common expected warnings may include workload accounts being located under the AWS Organizations root rather than under the expected `NonProd` or `Prod` OUs. This should be treated as a governance follow-up item unless account placement is explicitly managed by Terraform or required by the engagement scope.

---

## Manual Validation Results

The automated validation scripts are intentionally read-only. The following items should be reviewed manually where applicable.

| Manual Check | Status | Evidence / Notes |
|---|---|---|
| GitHub Actions workflow validation | `<Not Started/In Progress/Complete/Not Applicable>` | `<notes>` |
| IAM Identity Center end-user login and effective access testing | `<Not Started/In Progress/Complete/Not Applicable>` | `<notes>` |
| Identity Center group membership review | `<Not Started/In Progress/Complete/Not Applicable>` | `<notes>` |
| Live EC2 isolation test | `<Not Started/In Progress/Complete/Not Applicable>` | `<notes>` |
| Live EC2 rollback test | `<Not Started/In Progress/Complete/Not Applicable>` | `<notes>` |
| Live IP enrichment test | `<Not Started/In Progress/Complete/Not Applicable>` | `<notes>` |
| Tamper detection test | `<Not Started/In Progress/Complete/Not Applicable>` | `<notes>` |
| Break-glass role assumption test | `<Not Started/In Progress/Complete/Not Applicable>` | `<notes>` |
| Destroy safety review | `<Not Started/In Progress/Complete/Not Applicable>` | `<notes>` |

The automated control-plane validation script confirms selected control-plane resource presence and configuration. It does not execute GitHub workflows, test end-user SSO login, change Identity Center assignments, move AWS accounts between OUs, assume privileged roles, or perform destructive operations.

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
- AWS Organizations account placement warnings where OU placement is not currently managed by Terraform

---

## Evidence Files

### Workload Evidence Files

| File | Purpose |
|---|---|
| `summary.md` | Human-readable workload validation report |
| `summary.json` | Machine-readable workload validation summary |
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

### Control-Plane Evidence Files

| File | Purpose |
|---|---|
| `validate-control-plane.log` | Control-plane state backend, GitHub OIDC, AWS Organizations, and IAM Identity Center validation |
| `control-plane-validation-summary.md` | Optional human-readable summary of the control-plane validation run |
| `control-plane-validation-summary.json` | Optional machine-readable summary if control-plane export support is added |

---

## Limitations

This report validates deployed AWS control presence and selected configuration settings for the target workload environment and, where applicable, the supporting control plane.

The validation scripts confirm the presence and configuration of selected AWS security controls, governance resources, and supporting infrastructure at the time validation was run.

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