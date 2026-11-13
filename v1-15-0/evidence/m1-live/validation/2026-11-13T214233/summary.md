# tf-secure-baseline Workload Validation Report

This report summarizes automated read-only validation results for the `staging` workload environment.

## Executive Summary

| Field | Value |
|---|---|
| Overall result | **PASS** |
| Validation scripts passed | **16/16** |
| Validation scripts failed | **0/16** |
| Report Package Location | `validation-results/staging/baseline/2026-11-13T214233/` |

## Environment

| Field | Value |
|---|---|
| Project | tf-secure-baseline |
| Environment | staging |
| AWS Profile | `not set` |
| AWS Credential Source | `GitHub OIDC environment credentials` |
| AWS Region | us-east-1 |
| AWS Account ID | 027326805885 |
| Expected Account ID | 027326805885 |
| Name Prefix | tf-secure-baseline-staging |
| Validation Time | 2026-11-13T21:42:33+00:00 |
| Overall Result | PASS |
| Scripts Passed | 16/16 |
| Scripts Failed | 0/16 |

## Validation Summary

| Area | Script | Result | Log |
|---|---|---|---|
| Environment | `validate-env.sh` | PASS | `validate-env.log` |
| Networking | `validate-networking.sh` | PASS | `validate-networking.log` |
| VPC Endpoints | `validate-vpc-endpoints.sh` | PASS | `validate-vpc-endpoints.log` |
| ECR | `validate-ecr.sh` | PASS | `validate-ecr.log` |
| Logging | `validate-logging.sh` | PASS | `validate-logging.log` |
| Workload Security | `validate-security-workload.sh` | PASS | `validate-security-workload.log` |
| KMS | `validate-kms.sh` | PASS | `validate-kms.log` |
| Backup | `validate-backup.sh` | PASS | `validate-backup.log` |
| SNS | `validate-sns.sh` | PASS | `validate-sns.log` |
| SQS | `validate-sqs.sh` | PASS | `validate-sqs.log` |
| EventBridge | `validate-eventbridge.sh` | PASS | `validate-eventbridge.log` |
| Lambda | `validate-lambda.sh` | PASS | `validate-lambda.log` |
| SSM | `validate-ssm.sh` | PASS | `validate-ssm.log` |
| Compute | `validate-compute.sh` | PASS | `validate-compute.log` |
| ECS Runtime | `validate-ecs-runtime.sh` | PASS | `validate-ecs-runtime.log` |
| IAM | `validate-iam.sh` | PASS | `validate-iam.log` |

## Manual Validation Remaining

The automated validation suite is intentionally read-only. The following checks remain outside this workload baseline report:

- Full control-plane and AWS Organizations topology validation
- End-user SSO login validation
- Live EC2 isolation test
- Live EC2 rollback test
- Live IP enrichment test
- Tamper detection test
- Break-glass role assumption test
- Destroy safety review

## Evidence Files

This report directory contains the generated validation summary files and per-script logs.

| File | Purpose |
|---|---|
| `summary.md` | Human-readable validation report |
| `summary.json` | Machine-readable validation summary |
| `validate-env.log` | Log output for `validate-env.sh` |
| `validate-networking.log` | Log output for `validate-networking.sh` |
| `validate-vpc-endpoints.log` | Log output for `validate-vpc-endpoints.sh` |
| `validate-ecr.log` | Log output for `validate-ecr.sh` |
| `validate-logging.log` | Log output for `validate-logging.sh` |
| `validate-security-workload.log` | Log output for `validate-security-workload.sh` |
| `validate-kms.log` | Log output for `validate-kms.sh` |
| `validate-backup.log` | Log output for `validate-backup.sh` |
| `validate-sns.log` | Log output for `validate-sns.sh` |
| `validate-sqs.log` | Log output for `validate-sqs.sh` |
| `validate-eventbridge.log` | Log output for `validate-eventbridge.sh` |
| `validate-lambda.log` | Log output for `validate-lambda.sh` |
| `validate-ssm.log` | Log output for `validate-ssm.sh` |
| `validate-compute.log` | Log output for `validate-compute.sh` |
| `validate-ecs-runtime.log` | Log output for `validate-ecs-runtime.sh` |
| `validate-iam.log` | Log output for `validate-iam.sh` |

## Limitations

This report validates deployed AWS control presence and selected configuration settings for the target workload environment.

The validation suite confirms the presence and configuration of selected AWS security controls in the deployed environment.

This report does not replace a full SOC 2 or ISO 27001 audit, control owner review, policy review, evidence review, risk assessment, or ISMS.
