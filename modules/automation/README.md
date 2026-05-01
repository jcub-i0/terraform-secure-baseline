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

```
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
```

---

## Resources Created

This module creates resources for three automation workflows:

### EC2 Isolation

- Lambda deployment package
- EC2 Isolation Lambda function
- Lambda security group
- EventBridge rule for HIGH / CRITICAL EC2 Security Hub findings
- EventBridge target
- Lambda invoke permission
- CloudWatch log group

### EC2 Rollback

- Lambda deployment package
- EC2 Rollback Lambda function
- Lambda security group
- Custom SecOps EventBridge bus
- EventBridge bus policy
- EventBridge rollback rule
- EventBridge target
- Lambda invoke permission
- CloudWatch log group

### IP Enrichment

- Lambda deployment package
- IP Enrichment Lambda function
- Secrets Manager secret for threat intelligence API keys
- Secrets Manager secret version
- EventBridge rule for HIGH / CRITICAL Security Hub findings
- EventBridge target
- Lambda invoke permission
- CloudWatch log group

---

## Automation Workflows

## EC2 Isolation

The EC2 Isolation workflow is triggered by new HIGH or CRITICAL Security Hub findings involving EC2 instances.

When triggered, the Lambda function is designed to isolate affected EC2 instances by moving them into the Quarantine Security Group.

### Trigger

```
source      = aws.securityhub
detail-type = Security Hub Findings - Imported
severity    = HIGH or CRITICAL
resource    = AwsEc2Instance
workflow    = NEW
```

### Behavior

The Lambda function receives the Security Hub finding, identifies affected EC2 instances, snapshots the attaches EBS volume(s), applies quarantine controls, and sends an SNS notification.

---

## EC2 Rollback

The EC2 Rollback workflow restores isolated EC2 instances to their previous security group configuration.

This workflow is intentionally triggered through a custom SecOps EventBridge bus instead of the default event bus.

### Trigger

```
event bus = secops-bus
source    = custom.rollback
```

### Behavior

A SecOps Operator sends a controlled rollback event to the custom event bus. EventBridge invokes the rollback Lambda, which restores the instance security group configuration and sends an SNS alert.

This workflow supports an auditable manual recovery path after automated isolation.

---

## IP Enrichment

The IP enrichment workflow is triggered by new HIGH or CRITICAL Security Hub findings.

The Lambda function enriches IP address indicators using an external threat intelligence provider and sends the enrichment results to SNS.

### Trigger

```
source      = aws.securityhub
detail-type = Security Hub Findings - Imported
severity    = HIGH or CRITICAL
workflow    = NEW
```

### Threat Intel Secret

The module stores the AbuseIPDB API key in AWS Secrets Manager.

```
Secret name prefix:
<name_prefix>/threat-intel/api-keys-
```

The IP Enrichment Lambda reads the secret at runtime.

---

## Security Design

This module follows several security-focused design choices:

- Lambda functions use dedicated IAM roles passed into the module
- Lambda environment variables reference SNS topics, security groups, and secrets
- Lambda function code is encrypted with a Lambda CMK
- CloudWatch log groups are encrypted with the logs CMK
- Threat intelligence API keys are stored in Secrets Manager
- EC2 Isolation and rollback Lambdas run inside private serverless subnets
- EC2 Rollback is routed through a custom EventBridge bus
- IP Enrichment does not use a VPC configuration so it can reach external threat intelligence APIs without requiring NAT

---

## Usage

```hcl
module "automation" {
  source = "../modules/automation"

  cloud_name                               = var.cloud_name
  account_id                               = data.aws_caller_identity.current.account_id
  name_prefix                              = local.name_prefix
  environment                              = var.environment
  primary_region                           = var.primary_region

  vpc_id                                   = module.networking.vpc_id
  serverless_private_subnet_ids            = module.networking.serverless_private_subnet_ids_list
  interface_endpoints_sg_id                = module.vpc_endpoints.interface_endpoints_sg_id
  quarantine_sg_id                         = module.compute.quarantine_sg_id

  lambda_ec2_isolation_role_arn            = module.iam.lambda_ec2_isolation_role_arn
  lambda_ec2_rollback_role_arn             = module.iam.lambda_ec2_rollback_role_arn
  lambda_ip_enrichment_role_arn            = module.iam.lambda_ip_enrichment_role_arn
  eventbridge_putevents_to_secops_role_arn = module.iam.eventbridge_putevents_to_secops_role_arn

  secops_topic_arn                         = module.monitoring.secops_topic_arn
  lambda_cmk_arn                           = module.security.lambda_cmk_arn
  logs_cmk_arn                             = module.security.logs_cmk_arn
  secrets_manager_cmk_arn                  = module.security.secrets_manager_cmk_arn

  abuseipdb_api_key                        = var.abuseipdb_api_key

  ip_enrichment_write_to_securityhub       = var.ip_enrichment_write_to_securityhub
  ip_enrich_max_ips_per_event              = var.ip_enrich_max_ips_per_event
  ip_enrich_abuseipdb_max_age              = var.ip_enrich_abuseipdb_max_age
  ip_enrich_max_ips_extracted              = var.ip_enrich_max_ips_extracted
}
```

---

## Inputs

| Name | Description |
|------|-------------|
| `vpc_id` | VPC ID used for Lambda security groups |
| `name_prefix` | Naming prefix used for created resources |
| `cloud_name` | Name of the cloud environment |
| `environment` | Environment name, such as `dev`, `staging`, or `prod` |
| `lambda_ec2_isolation_role_arn` | IAM role ARN for the EC2 isolation Lambda |
| `lambda_ec2_rollback_role_arn` | IAM role ARN for the EC2 rollback Lambda |
| `lambda_ip_enrichment_role_arn` | IAM role ARN for the IP enrichment Lambda |
| `serverless_private_subnet_ids` | Private subnet IDs used by VPC-enabled Lambda functions |
| `quarantine_sg_id` | Security group ID used to isolate EC2 instances |
| `secops_topic_arn` | SNS topic ARN for SecOps notifications |
| `account_id` | AWS account ID where automation resources are deployed |
| `primary_region` | Primary AWS region |
| `eventbridge_putevents_to_secops_role_arn` | IAM role ARN used for putting events onto the SecOps event bus |
| `lambda_cmk_arn` | KMS CMK ARN used to encrypt Lambda functions |
| `secrets_manager_cmk_arn` | KMS CMK ARN used to encrypt Secrets Manager secrets |
| `interface_endpoints_sg_id` | Security group ID used by VPC interface endpoints |
| `logs_cmk_arn` | KMS CMK ARN used to encrypt Lambda CloudWatch log groups |
| `ip_enrichment_write_to_securityhub` | Controls whether IP enrichment writes results back to Security Hub |
| `abuseipdb_api_key` | Sensitive AbuseIPDB API key stored in Secrets Manager |
| `ip_enrich_max_ips_per_event` | Maximum number of IPs enriched per Security Hub event |
| `ip_enrich_abuseipdb_max_age` | AbuseIPDB max age filter in days |
| `ip_enrich_max_ips_extracted` | Maximum number of IPs extracted from a finding |

---

## Outputs

| Name | Description |
|------|-------------|
| `secops_event_bus_name` | Name of the custom SecOps EventBridge bus |
| `secops_event_bus_arn` | ARN of the custom SecOps EventBridge bus |
| `lambda_ec2_isolation_sg_id` | Security group ID for the EC2 isolation Lambda |
| `lambda_ec2_rollback_sg_id` | Security group ID for the EC2 rollback Lambda |
| `threat_intel_api_keys_arn` | ARN of the Secrets Manager secret storing threat intelligence API keys |
| `lambda_ip_enrichment_log_group_arn` | ARN of the CloudWatch log group for the IP enrichment Lambda |
| `securityhub_high_critical_rule_arn` | ARN of the EventBridge rule for HIGH / CRITICAL Security Hub findings |
| `securityhub_high_critical_rule_name` | Name of the EventBridge rule for HIGH / CRITICAL Security Hub findings |

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