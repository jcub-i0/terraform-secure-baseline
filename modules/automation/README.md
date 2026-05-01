# Automation Module

## Overview

The `automation` module deploys event-driven security automation for the AWS security baseline.

It creates Lambda functions, EventBridge rules, EventBridge targets, Lambda permissions, CloudWatch log groups, supporting security groups, a custom SecOps event bus, and a Secrets Manager secret for threat intelligence API keys.

This module is responsible for automated response and enrichment workflows used by the baseline.

---

## Purpose

This module provides automation for:

- Isolating EC2 instances based on high-severity Security Hub findings
- Rolling back isolated EC2 instances through a controlled SecOps workflow
- Enriching Security Hub findings with external threat intelligence
- Routing security events through EventBridge
- Sending operational alerts to SNS

---

## Architecture

%%%
Security Hub Finding
    |
    +--> EventBridge Rule: HIGH / CRITICAL EC2 Finding
    |       |
    |       v
    |   EC2 Isolation Lambda
    |       |
    |       v
    |   Quarantine Security Group + SNS Alert
    |
    +--> EventBridge Rule: HIGH / CRITICAL Finding
            |
            v
        IP Enrichment Lambda
            |
            v
        Threat Intel Lookup + SNS Alert


SecOps Operator
    |
    | custom.rollback event
    v
Custom EventBridge Bus: secops-bus
    |
    v
EC2 Rollback Lambda
    |
    v
Restore Original Security Groups + SNS Alert
%%%

---

## Resources Created

This module creates resources for three automation workflows:

### EC2 Isolation

- Lambda deployment package
- EC2 isolation Lambda function
- Lambda security group
- EventBridge rule for HIGH / CRITICAL EC2 Security Hub findings
- EventBridge target
- Lambda invoke permission
- CloudWatch log group

### EC2 Rollback

- Lambda deployment package
- EC2 rollback Lambda function
- Lambda security group
- Custom SecOps EventBridge bus
- EventBridge bus policy
- EventBridge rollback rule
- EventBridge target
- Lambda invoke permission
- CloudWatch log group

### IP Enrichment

- Lambda deployment package
- IP enrichment Lambda function
- Secrets Manager secret for threat intelligence API keys
- Secrets Manager secret version
- EventBridge rule for HIGH / CRITICAL Security Hub findings
- EventBridge target
- Lambda invoke permission
- CloudWatch log group

---

## Automation Workflows

## EC2 Isolation

The EC2 isolation workflow is triggered by new HIGH or CRITICAL Security Hub findings involving EC2 instances.

When triggered, the Lambda function is designed to isolate affected EC2 instances by moving them into the quarantine security group.

### Trigger

%%%
source      = aws.securityhub
detail-type = Security Hub Findings - Imported
severity    = HIGH or CRITICAL
resource    = AwsEc2Instance
workflow    = NEW
%%%

### Behavior

The Lambda function receives the Security Hub finding, identifies affected EC2 instances, applies quarantine controls, and sends an SNS notification.

---

## EC2 Rollback

The EC2 rollback workflow restores isolated EC2 instances to their previous security group configuration.

This workflow is intentionally triggered through a custom SecOps EventBridge bus instead of the default event bus.

### Trigger

%%%
event bus = secops-bus
source    = custom.rollback
%%%

### Behavior

A SecOps operator sends a controlled rollback event to the custom event bus. EventBridge invokes the rollback Lambda, which restores the instance security group configuration and sends an SNS alert.

This workflow supports an auditable manual recovery path after automated isolation.

---

## IP Enrichment

The IP enrichment workflow is triggered by new HIGH or CRITICAL Security Hub findings.

The Lambda function enriches IP address indicators using an external threat intelligence provider and sends the enrichment results to SNS.

### Trigger

%%%
source      = aws.securityhub
detail-type = Security Hub Findings - Imported
severity    = HIGH or CRITICAL
workflow    = NEW
%%%

### Threat Intel Secret

The module stores the AbuseIPDB API key in AWS Secrets Manager.

%%%
Secret name prefix:
<name_prefix>/threat-intel/api-keys-
%%%

The IP enrichment Lambda reads the secret at runtime.

---

## Security Design

This module follows several security-focused design choices:

- Lambda functions use dedicated IAM roles passed into the module
- Lambda environment variables reference SNS topics, security groups, and secrets
- Lambda function code is encrypted with a Lambda# Automation Module

The `automation` module provisions security automation workflows driven by AWS Security Hub findings. It deploys Lambda responders, EventBridge rules/bus integrations, encrypted logging, and secret management to support automated containment and controlled recovery.

## What this module does

The module creates three automation pipelines:

1. **EC2 isolation automation**
   - Packages and deploys `ec2_isolation.py` as a Lambda function.
   - Listens for **HIGH/CRITICAL** Security Hub findings on `AwsEc2Instance` resources with workflow status `NEW`.
   - Takes EBS snapshots before isolation.
   - Replaces instance security groups with a quarantine SG.
   - Tags the instance with isolation metadata and notifies a SecOps SNS topic.

2. **EC2 rollback automation**
   - Packages and deploys `ec2_rollback.py` as a Lambda function.
   - Creates a dedicated **SecOps EventBridge custom bus** and bus policy for rollback event intake.
   - Invokes rollback Lambda on `custom.rollback` events.
   - Restores original security groups from instance tags, writes release/audit tags, and sends SNS notification.

3. **IP enrichment automation**
   - Packages and deploys `ip_enrichment.py` as a Lambda function.
   - Listens for **HIGH/CRITICAL** Security Hub findings.
   - Extracts public IPs from findings and enriches reputation context via AbuseIPDB.
   - Publishes formatted enrichment reports to SNS.
   - Optionally writes enrichment notes back into Security Hub findings.
   - Stores threat intel API keys in AWS Secrets Manager (KMS-encrypted).

Across all Lambdas, the module enables X-Ray tracing and provisions KMS-encrypted CloudWatch log groups.

## Resources created (high level)

- Lambda functions:
  - `${name_prefix}-ec2-isolation`
  - `${name_prefix}-ec2-rollback`
  - `${name_prefix}-ip-enrichment`
- Lambda security groups for isolation and rollback handlers
- EventBridge rules/targets/permissions for Security Hub-triggered and manual rollback flows
- EventBridge custom bus: `${name_prefix}-secops-bus`
- Event bus policy scoped to approved event sources
- CloudWatch log groups (30-day retention, KMS key)
- Secrets Manager secret + version for threat intel API keys

## Input Variables

| Name | Type | Description |
|---|---|---|
| `vpc_id` | `string` | VPC ID used for Lambda security groups and VPC-attached functions. |
| `name_prefix` | `string` | Prefix used for naming resources. |
| `cloud_name` | `string` | Environment/cloud identifier used by IP enrichment (e.g., User-Agent, Security Hub note author). |
| `environment` | `string` | Environment tag value (e.g., dev, staging, prod). |
| `lambda_ec2_isolation_role_arn` | `string` | IAM role ARN for the EC2 isolation Lambda. |
| `lambda_ec2_rollback_role_arn` | `string` | IAM role ARN for the EC2 rollback Lambda. |
| `lambda_ip_enrichment_role_arn` | `string` | IAM role ARN for the IP enrichment Lambda. |
| `serverless_private_subnet_ids` | `list(string)` | Private subnet IDs for VPC-attached Lambdas (isolation/rollback). |
| `quarantine_sg_id` | `string` | Security group ID applied to EC2 instances during automated isolation. |
| `secops_topic_arn` | `string` | SNS topic ARN for SecOps notifications from all automations. |
| `account_id` | `string` | AWS account ID used in EventBridge bus policy conditions/principals. |
| `primary_region` | `string` | Primary AWS region (declared input; useful for caller-level conventions). |
| `eventbridge_putevents_to_secops_role_arn` | `string` | EventBridge PutEvents role ARN (declared input; intended for caller-level integration patterns). |
| `lambda_cmk_arn` | `string` | KMS CMK ARN for Lambda environment encryption. |
| `secrets_manager_cmk_arn` | `string` | KMS CMK ARN used for Secrets Manager encryption. |
| `interface_endpoints_sg_id` | `string` | Interface endpoint SG ID (declared input; reserved for integration constraints). |
| `logs_cmk_arn` | `string` | KMS CMK ARN for CloudWatch log group encryption. |
| `ip_enrichment_write_to_securityhub` | `bool` | Whether IP enrichment writes notes back to Security Hub findings. |
| `abuseipdb_api_key` | `string (sensitive)` | AbuseIPDB API key stored into Secrets Manager secret version. |
| `ip_enrich_max_ips_per_event` | `string` | Max public IPs enriched per invocation. |
| `ip_enrich_abuseipdb_max_age` | `string` | `maxAgeInDays` sent to AbuseIPDB API queries. |
| `ip_enrich_max_ips_extracted` | `string` | Upper limit of IPs extracted from findings before truncation. |

## Outputs

| Name | Description |
|---|---|
| `secops_event_bus_name` | Name of the custom SecOps EventBridge bus. |
| `secops_event_bus_arn` | ARN of the custom SecOps EventBridge bus. |
| `lambda_ec2_isolation_sg_id` | Security group ID for EC2 isolation Lambda. |
| `lambda_ec2_rollback_sg_id` | Security group ID for EC2 rollback Lambda. |
| `threat_intel_api_keys_arn` | ARN of Secrets Manager secret storing threat intel API keys. |
| `lambda_ip_enrichment_log_group_arn` | ARN of the IP enrichment Lambda CloudWatch log group. |
| `securityhub_high_critical_rule_arn` | ARN of Security Hub HIGH/CRITICAL EventBridge rule used by enrichment. |
| `securityhub_high_critical_rule_name` | Name of Security Hub HIGH/CRITICAL EventBridge rule used by enrichment. |

## Example usage

```hcl
module "automation" {
  source = "../../modules/automation"

  vpc_id                                = module.networking.vpc_id
  name_prefix                           = local.name_prefix
  cloud_name                            = local.cloud_name
  environment                           = var.environment

  lambda_ec2_isolation_role_arn         = module.iam.lambda_ec2_isolation_role_arn
  lambda_ec2_rollback_role_arn          = module.iam.lambda_ec2_rollback_role_arn
  lambda_ip_enrichment_role_arn         = module.iam.lambda_ip_enrichment_role_arn

  serverless_private_subnet_ids         = module.networking.serverless_private_subnet_ids
  quarantine_sg_id                      = module.security.quarantine_sg_id
  secops_topic_arn                      = module.monitoring.secops_topic_arn

  account_id                            = data.aws_caller_identity.current.account_id
  primary_region                        = var.primary_region
  eventbridge_putevents_to_secops_role_arn = module.iam.eventbridge_putevents_to_secops_role_arn

  lambda_cmk_arn                        = module.security.lambda_cmk_arn
  secrets_manager_cmk_arn               = module.security.secrets_manager_cmk_arn
  interface_endpoints_sg_id             = module.vpc_endpoints.interface_endpoints_sg_id
  logs_cmk_arn                          = module.logging.logs_cmk_arn

  ip_enrichment_write_to_securityhub    = true
  abuseipdb_api_key                     = var.abuseipdb_api_key
  ip_enrich_max_ips_per_event           = "25"
  ip_enrich_abuseipdb_max_age           = "90"
  ip_enrich_max_ips_extracted           = "200"
}
```

## Operational notes

- Ensure Lambda IAM roles include least-privilege permissions for EC2, SNS, CloudWatch Logs, X-Ray, Security Hub, Secrets Manager, and KMS as appropriate for each function.
- `abuseipdb_api_key` is sensitive and should be provided via secure variable handling (e.g., CI secret store, encrypted tfvars).
- Rollback events must be sent to the custom bus with `source = "custom.rollback"` and include `instance_id`, `approved_by`, and `ticket_id` in `detail`.
- IP enrichment runs outside VPC by design to allow direct internet egress without NAT dependency.
 CMK
- CloudWatch log groups are encrypted with the logs CMK
- Threat intelligence API keys are stored in Secrets Manager
- EC2 isolation and rollback Lambdas run inside private serverless subnets
- EC2 rollback is routed through a custom EventBridge bus
- IP enrichment does not use a VPC configuration so it can reach external threat intelligence APIs without requiring NAT

---

## Usage

%%%hcl
module "automation" {
  source = "../../modules/automation"

  cloud_name  = var.cloud_name
  environment = var.environment
  name_prefix = local.name_prefix
  account_id  = var.account_id

  vpc_id                        = module.networking.vpc_id
  serverless_private_subnet_ids = module.networking.serverless_private_subnet_ids
  quarantine_sg_id              = module.networking.quarantine_sg_id

  lambda_ec2_isolation_role_arn = module.iam.lambda_ec2_isolation_role_arn
  lambda_ec2_rollback_role_arn  = module.iam.lambda_ec2_rollback_role_arn
  lambda_ip_enrichment_role_arn = module.iam.lambda_ip_enrichment_role_arn

  secops_topic_arn        = module.monitoring.secops_topic_arn
  lambda_cmk_arn          = module.logging.lambda_cmk_arn
  logs_cmk_arn            = module.logging.logs_cmk_arn
  secrets_manager_cmk_arn = module.logging.secrets_manager_cmk_arn

  abuseipdb_api_key = var.abuseipdb_api_key

  ip_enrichment_write_to_securityhub = false
  ip_enrich_max_ips_per_event        = 5
  ip_enrich_abuseipdb_max_age        = 90
  ip_enrich_max_ips_extracted        = 25
}
%%%

---

## Inputs

| Name | Description |
|------|-------------|
| `cloud_name` | Name of the cloud environment |
| `environment` | Environment name, such as `dev`, `staging`, or `prod` |
| `name_prefix` | Naming prefix used for created resources |
| `account_id` | AWS account ID where automation resources are deployed |
| `vpc_id` | VPC ID used for Lambda security groups |
| `serverless_private_subnet_ids` | Private subnet IDs used by VPC-enabled Lambda functions |
| `quarantine_sg_id` | Security group ID used to isolate EC2 instances |
| `lambda_ec2_isolation_role_arn` | IAM role ARN for the EC2 isolation Lambda |
| `lambda_ec2_rollback_role_arn` | IAM role ARN for the EC2 rollback Lambda |
| `lambda_ip_enrichment_role_arn` | IAM role ARN for the IP enrichment Lambda |
| `secops_topic_arn` | SNS topic ARN for SecOps notifications |
| `lambda_cmk_arn` | KMS CMK ARN used to encrypt Lambda functions |
| `logs_cmk_arn` | KMS CMK ARN used to encrypt Lambda CloudWatch log groups |
| `secrets_manager_cmk_arn` | KMS CMK ARN used to encrypt Secrets Manager secrets |
| `abuseipdb_api_key` | AbuseIPDB API key stored in Secrets Manager |
| `ip_enrichment_write_to_securityhub` | Controls whether IP enrichment writes results back to Security Hub |
| `ip_enrich_max_ips_per_event` | Maximum number of IPs enriched per Security Hub event |
| `ip_enrich_abuseipdb_max_age` | AbuseIPDB max age filter in days |
| `ip_enrich_max_ips_extracted` | Maximum number of IPs extracted from a finding |

---

## Outputs

| Name | Description |
|------|-------------|
| `ec2_isolation_lambda_name` | Name of the EC2 isolation Lambda function |
| `ec2_isolation_lambda_arn` | ARN of the EC2 isolation Lambda function |
| `ec2_rollback_lambda_name` | Name of the EC2 rollback Lambda function |
| `ec2_rollback_lambda_arn` | ARN of the EC2 rollback Lambda function |
| `ip_enrichment_lambda_name` | Name of the IP enrichment Lambda function |
| `ip_enrichment_lambda_arn` | ARN of the IP enrichment Lambda function |
| `secops_event_bus_name` | Name of the custom SecOps EventBridge bus |
| `secops_event_bus_arn` | ARN of the custom SecOps EventBridge bus |
| `threat_intel_secret_arn` | ARN of the Secrets Manager secret storing threat intelligence API keys |

---

## Important Notes

- EC2 isolation is triggered only for new HIGH or CRITICAL Security Hub findings involving EC2 instances.
- EC2 rollback is triggered through the custom SecOps event bus using the `custom.rollback` source.
- The IP enrichment Lambda is intentionally not placed in a VPC so it can reach external threat intelligence APIs without NAT.
- Lambda IAM roles are created outside this module and passed in as inputs.
- CloudWatch log groups are created explicitly so retention and KMS encryption can be controlled.
- The AbuseIPDB API key is stored in Secrets Manager and encrypted with the provided Secrets Manager CMK.

---

## Summary

The `automation` module provides the baseline’s event-driven security response layer.

It connects Security Hub, EventBridge, Lambda, SNS, Secrets Manager, and CloudWatch Logs to support automated EC2 isolation, controlled rollback, and threat intelligence enrichment.