# Automation Module

## Overview

The `automation` module deploys event-driven security automation for the AWS security baseline.

It creates the Lambda functions, EventBridge rules, EventBridge targets, Lambda permissions, CloudWatch log groups, SQS DLQs, DLQ alarms, supporting Lambda security groups, a custom SecOps EventBridge bus, and a Secrets Manager secret used by the threat intelligence workflow.

This module is responsible for the baseline's automated response and enrichment workflows.

---

## Purpose

This module provides automation for:

- Isolating EC2 instances based on high-severity Security Hub findings
- Rolling back isolated EC2 instances through a controlled SecOps workflow
- Enriching Security Hub findings with external threat intelligence
- Routing workflow events through EventBridge
- Retaining failed automation events in workflow-specific DLQs
- Alerting SecOps when automation DLQs receive messages

---

## Architecture

```text
Security Hub Finding
    |
    +--> EventBridge Rule: HIGH / CRITICAL EC2 Finding
    |       |
    |       v
    |   EC2 Isolation Lambda
    |       |
    |       +--> Quarantine Security Group + SNS Alert
    |       |
    |       +--> EC2 Isolation DLQ
    |
    +--> EventBridge Rule: HIGH / CRITICAL Finding
            |
            v
        IP Enrichment Lambda
            |
            +--> Threat Intel Lookup + SNS Alert
            |
            +--> IP Enrichment DLQ

SecOps Operator
    |
    | custom.rollback event
    v
Custom EventBridge Bus: secops-bus
    |
    v
EC2 Rollback Lambda
    |
    +--> Restore Original Security Groups + SNS Alert
    |
    +--> EC2 Rollback DLQ
```

The workflow DLQs are encrypted SQS queues used to retain failed automation events for investigation and manual remediation.

---

## Automation Workflows

### EC2 Isolation

The EC2 Isolation workflow is triggered by new HIGH or CRITICAL Security Hub findings involving EC2 instances.

When triggered, the Lambda function identifies affected EC2 instances, snapshots attached EBS volumes, preserves the original security group state, applies quarantine controls, tags the instance, and sends an SNS notification.

#### Trigger

```text
source      = aws.securityhub
detail-type = Security Hub Findings - Imported
severity    = HIGH or CRITICAL
resource    = AwsEc2Instance
workflow    = NEW
```

#### Resources

| Resource | Purpose |
|---|---|
| `aws_lambda_function.ec2_isolation` | Runs the EC2 isolation workflow |
| `aws_security_group.lambda_ec2_isolation_sg` | Security group for the VPC-enabled Lambda |
| `aws_cloudwatch_event_rule.securityhub_ec2_high_critical` | Matches high/critical EC2 Security Hub findings |
| `aws_cloudwatch_event_target.ec2_isolation` | Sends matching findings to the Lambda |
| `aws_lambda_permission.allow_eventbridge_ec2_isolation` | Allows EventBridge to invoke the Lambda |
| `aws_lambda_function_event_invoke_config.ec2_isolation` | Sends asynchronous Lambda processing failures to the workflow DLQ |
| `aws_cloudwatch_log_group.lambda_ec2_isolation` | Stores encrypted Lambda logs |
| `aws_sqs_queue.ec2_isolation_dlq` | Retains failed EC2 isolation events |
| `aws_sqs_queue_policy.ec2_isolation_dlq` | Allows EventBridge and the Lambda role to send failure messages |
| `aws_cloudwatch_metric_alarm.ec2_isolation_dlq_visible_messages` | Alerts when messages are visible in the DLQ |

---

### EC2 Rollback

The EC2 Rollback workflow restores isolated EC2 instances to their previous security group configuration.

This workflow is intentionally triggered through a custom SecOps EventBridge bus instead of the default event bus. The bus policy limits rollback events to the expected event source.

#### Trigger

```text
event bus = <name_prefix>-secops-bus
source    = custom.rollback
```

#### Resources

| Resource | Purpose |
|---|---|
| `aws_lambda_function.ec2_rollback` | Runs the rollback workflow |
| `aws_security_group.lambda_ec2_rollback_sg` | Security group for the VPC-enabled Lambda |
| `aws_cloudwatch_event_bus.secops` | Custom EventBridge bus for SecOps workflows |
| `aws_cloudwatch_event_bus_policy.secops_bus_policy` | Restricts allowed event sources on the custom bus |
| `aws_cloudwatch_event_rule.ec2_rollback` | Matches rollback events on the SecOps bus |
| `aws_cloudwatch_event_target.ec2_rollback` | Sends rollback events to the Lambda |
| `aws_lambda_permission.allow_eventbridge_ec2_rollback` | Allows EventBridge to invoke the Lambda |
| `aws_cloudwatch_log_group.lambda_ec2_rollback` | Stores encrypted Lambda logs |
| `aws_sqs_queue.ec2_rollback_dlq` | Retains failed rollback events |
| `aws_sqs_queue_policy.ec2_rollback_dlq` | Allows EventBridge and the Lambda role to send failure messages |
| `aws_cloudwatch_metric_alarm.ec2_rollback_dlq_visible_messages` | Alerts when messages are visible in the DLQ |

---

### IP Enrichment

The IP Enrichment workflow is triggered by new HIGH or CRITICAL Security Hub findings.

The Lambda function extracts public IP indicators, queries the configured threat intelligence provider, and sends enrichment results to the SecOps SNS topic. The function can optionally write enrichment notes back to Security Hub.

#### Trigger

```text
source      = aws.securityhub
detail-type = Security Hub Findings - Imported
severity    = HIGH or CRITICAL
workflow    = NEW
```

#### Threat Intel Secret

The AbuseIPDB API key is stored in AWS Secrets Manager.

```text
Secret name prefix:
<name_prefix>/threat-intel/api-keys-
```

The secret is encrypted with the Secrets Manager CMK passed into the module.

#### Resources

| Resource | Purpose |
|---|---|
| `aws_lambda_function.ip_enrichment` | Runs threat intelligence enrichment |
| `aws_secretsmanager_secret.threat_intel_api_keys` | Stores threat intelligence API credentials |
| `aws_secretsmanager_secret_version.threat_intel_api_keys` | Stores the current AbuseIPDB API key value |
| `aws_cloudwatch_event_rule.securityhub_high_critical` | Matches high/critical Security Hub findings |
| `aws_cloudwatch_event_target.ip_enrichment` | Sends matching findings to the Lambda |
| `aws_lambda_permission.allow_eventbridge_ip_enrichment` | Allows EventBridge to invoke the Lambda |
| `aws_cloudwatch_log_group.lambda_ip_enrichment` | Stores encrypted Lambda logs |
| `aws_sqs_queue.ip_enrichment_dlq` | Retains failed IP enrichment events |
| `aws_sqs_queue_policy.ip_enrichment_dlq` | Allows EventBridge and the Lambda role to send failure messages |
| `aws_cloudwatch_metric_alarm.ip_enrichment_dlq_visible_messages` | Alerts when messages are visible in the DLQ |

---

## Failure Handling

Each automation workflow has a dedicated SQS DLQ.

| Workflow | DLQ Name Format | Retention | Encryption |
|---|---|---:|---|
| EC2 Isolation | `<name_prefix>-ec2-isolation-dlq` | 14 days | logs CMK |
| EC2 Rollback | `<name_prefix>-ec2-rollback-dlq` | 14 days | logs CMK |
| IP Enrichment | `<name_prefix>-ip-enrichment-dlq` | 14 days | logs CMK |

EventBridge targets use:

```text
maximum_retry_attempts       = 3
maximum_event_age_in_seconds = 3600
```

DLQ queue policies allow `events.amazonaws.com` to send messages from the matching EventBridge rule. They also allow the corresponding Lambda execution role to send failure messages.

DLQs are terminal failure-retention queues. Messages are not automatically replayed by this module.

---

## DLQ Alarms

Each workflow DLQ has a CloudWatch alarm on:

```text
AWS/SQS ApproximateNumberOfMessagesVisible
```

The alarms notify the SecOps SNS topic when messages are visible in a DLQ.

| Alarm | Queue |
|---|---|
| `<name_prefix>-ec2-isolation-dlq-visible-messages` | EC2 Isolation DLQ |
| `<name_prefix>-ec2-rollback-dlq-visible-messages` | EC2 Rollback DLQ |
| `<name_prefix>-ip-enrichment-dlq-visible-messages` | IP Enrichment DLQ |

A visible DLQ message should be treated as an operational signal that the automation workflow needs review.

---

## Security Design

This module follows several security-focused design choices:

- Lambda functions use dedicated IAM roles passed into the module.
- Lambda function code is encrypted with the Lambda CMK.
- Lambda CloudWatch log groups are encrypted with the logs CMK.
- Workflow DLQs are encrypted with the logs CMK.
- Threat intelligence API keys are stored in Secrets Manager and encrypted with the Secrets Manager CMK.
- EC2 Isolation and EC2 Rollback Lambdas run inside private serverless subnets.
- IP Enrichment intentionally does not use a VPC configuration so it can reach external threat intelligence APIs without requiring NAT.
- EC2 Rollback is routed through a custom EventBridge bus.
- EventBridge targets use retry policies and DLQs.
- DLQ send permissions are scoped to expected EventBridge rule ARNs and Lambda execution roles.

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

  cloudwatch_retention_days                = local.effective_cloudwatch_retention_days

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
|---|---|
| `vpc_id` | VPC ID used for Lambda security groups |
| `name_prefix` | Naming prefix used for created resources |
| `cloud_name` | Name of the cloud environment |
| `environment` | Environment name, such as `dev`, `staging`, or `prod` |
| `lambda_ec2_isolation_role_arn` | IAM role ARN for the EC2 Isolation Lambda |
| `lambda_ec2_rollback_role_arn` | IAM role ARN for the EC2 Rollback Lambda |
| `lambda_ip_enrichment_role_arn` | IAM role ARN for the IP Enrichment Lambda |
| `serverless_private_subnet_ids` | Private subnet IDs used by VPC-enabled Lambda functions |
| `quarantine_sg_id` | Security group ID used to isolate EC2 instances |
| `secops_topic_arn` | SNS topic ARN for SecOps notifications |
| `account_id` | AWS account ID where automation resources are deployed |
| `primary_region` | Primary AWS region |
| `eventbridge_putevents_to_secops_role_arn` | IAM role ARN used for EventBridge SecOps integrations |
| `lambda_cmk_arn` | KMS CMK ARN used to encrypt Lambda functions |
| `secrets_manager_cmk_arn` | KMS CMK ARN used to encrypt Secrets Manager secrets |
| `interface_endpoints_sg_id` | Security group ID used by VPC interface endpoints |
| `logs_cmk_arn` | KMS CMK ARN used to encrypt Lambda CloudWatch log groups and workflow DLQs |
| `cloudwatch_retention_days` | Retention period for Lambda CloudWatch log groups |
| `ip_enrichment_write_to_securityhub` | Controls whether IP enrichment writes results back to Security Hub |
| `abuseipdb_api_key` | Sensitive AbuseIPDB API key stored in Secrets Manager |
| `ip_enrich_max_ips_per_event` | Maximum number of IPs enriched per Security Hub event |
| `ip_enrich_abuseipdb_max_age` | AbuseIPDB max age filter in days |
| `ip_enrich_max_ips_extracted` | Maximum number of IPs extracted from a finding |

---

## Outputs

| Name | Description |
|---|---|
| `secops_event_bus_name` | Name of the custom SecOps EventBridge bus |
| `secops_event_bus_arn` | ARN of the custom SecOps EventBridge bus |
| `lambda_ec2_isolation_sg_id` | Security group ID for the EC2 Isolation Lambda |
| `lambda_ec2_isolation_dlq_arn` | ARN of the EC2 Isolation workflow DLQ |
| `lambda_ec2_rollback_sg_id` | Security group ID for the EC2 Rollback Lambda |
| `lambda_ec2_rollback_dlq_arn` | ARN of the EC2 Rollback workflow DLQ |
| `threat_intel_api_keys_arn` | ARN of the Secrets Manager secret storing threat intelligence API keys |
| `lambda_ip_enrichment_log_group_arn` | ARN of the CloudWatch log group for the IP Enrichment Lambda |
| `lambda_ip_enrichment_dlq_arn` | ARN of the IP Enrichment workflow DLQ |
| `securityhub_high_critical_rule_arn` | ARN of the EventBridge rule for HIGH / CRITICAL Security Hub findings |
| `securityhub_high_critical_rule_name` | Name of the EventBridge rule for HIGH / CRITICAL Security Hub findings |

---

## Validation

Use the automated validation suite as the primary validation path:

```bash
./scripts/validation/validate-lambda.sh dev
./scripts/validation/validate-eventbridge.sh dev
./scripts/validation/validate-sqs.sh dev
```

Expected coverage includes:

- Lambda functions exist and are active
- Lambda runtime, timeout, memory, KMS configuration, and VPC configuration match expectations
- Lambda CloudWatch log groups exist and are encrypted
- EventBridge rules exist on the expected buses
- EventBridge targets point to the expected Lambda functions
- EventBridge targets have retry policies and DLQs
- Workflow DLQs exist and are encrypted
- Workflow DLQ queue policies exist
- Workflow DLQ alarms exist and point to the SecOps notification topic

Manual live workflow tests are intentionally outside the default validation suite because they can change workload state.

---

## Operational Considerations

### DLQ Messages

A message in one of the automation DLQs means a security automation event failed delivery or processing and needs review.

Recommended response:

1. Identify the affected workflow from the queue name.
2. Inspect the DLQ message body and attributes.
3. Determine whether EventBridge delivery failed, Lambda processing failed, or downstream permissions/configuration failed.
4. Review the corresponding Lambda logs.
5. Fix the underlying issue.
6. Manually replay or remediate only after confirming the event is safe to process.

---

### EC2 Isolation Safety

EC2 Isolation changes instance security group attachments.

Use this workflow carefully in non-development environments and confirm rollback procedures are understood before enabling live response against production workloads.

---

### EC2 Rollback Control

Rollback uses a custom SecOps EventBridge bus and the `custom.rollback` source.

This provides a controlled recovery path without giving operators direct EC2 modification permissions.

---

### IP Enrichment Internet Access

The IP Enrichment Lambda intentionally does not use a VPC configuration.

This allows it to reach external threat intelligence APIs without requiring NAT. If the function is moved into a VPC in the future, outbound internet access must be provided another way.

---

### Secrets Manager Rotation

The module stores the AbuseIPDB API key in Secrets Manager.

Rotation is not configured in this module. If required, add a separate rotation workflow or operational process for updating the secret value.

---

## Troubleshooting

### EventBridge Target Is Not Invoking Lambda

Check:

- The EventBridge rule exists and is enabled.
- The target ARN points to the expected Lambda function.
- The Lambda permission allows `events.amazonaws.com` from the expected rule ARN.
- The event matches the rule pattern.
- The target DLQ does not contain failed delivery events.

---

### DLQ Alarm Fired

Check:

- Which workflow DLQ contains visible messages.
- The message body and attributes.
- The matching EventBridge rule and target configuration.
- The corresponding Lambda CloudWatch log group.
- KMS permissions for EventBridge, Lambda, SQS, and CloudWatch Logs.
- IAM permissions used by the Lambda execution role.

---

### EC2 Isolation Did Not Apply Quarantine

Check:

- The Security Hub finding is HIGH or CRITICAL.
- The finding resource type is `AwsEc2Instance`.
- The finding workflow status is `NEW`.
- The Lambda execution role can describe and modify EC2 instance security groups.
- The quarantine security group ID is correct.
- The Lambda has network access to required AWS service endpoints through the configured VPC path.

---

### EC2 Rollback Did Not Restore Security Groups

Check:

- The rollback event was sent to the custom SecOps event bus.
- The event source is `custom.rollback`.
- The EventBridge rollback rule exists on the SecOps bus.
- The Lambda execution role can read the preserved original security group metadata and modify EC2 instance security groups.
- The target DLQ and Lambda logs for the rollback workflow.

---

### IP Enrichment Did Not Return Results

Check:

- The finding contains public IP addresses.
- The AbuseIPDB API key secret exists.
- The Lambda execution role can read the secret.
- The API key is valid.
- The function has outbound internet access.
- The configured IP extraction and enrichment limits are appropriate.

---

## Important Notes

- EC2 Isolation is triggered only for new HIGH or CRITICAL Security Hub findings involving EC2 instances.
- EC2 Rollback is triggered through the custom SecOps event bus using the `custom.rollback` source.
- IP Enrichment is triggered by new HIGH or CRITICAL Security Hub findings.
- IP Enrichment is intentionally not placed in a VPC.
- Lambda IAM roles are created outside this module and passed in as inputs.
- CloudWatch log groups are created explicitly so retention and KMS encryption can be controlled.
- Workflow DLQs are encrypted with the logs CMK and retain messages for 14 days.
- DLQ messages are not automatically replayed.
- The AbuseIPDB API key is stored in Secrets Manager and encrypted with the provided Secrets Manager CMK.

---

## Summary

The `automation` module provides the baseline's event-driven security response layer.

It connects Security Hub, EventBridge, Lambda, SQS, SNS, Secrets Manager, and CloudWatch Logs to support automated EC2 isolation, controlled rollback, threat intelligence enrichment, and workflow failure retention.