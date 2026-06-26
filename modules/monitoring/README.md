# Monitoring Module

## Overview

The `monitoring` module provisions the notification and alert-routing layer for a `tf-secure-baseline` workload environment.

It creates encrypted SNS and SQS resources for security and compliance notifications, attaches selected EventBridge targets to the security notification path, and creates CloudWatch metric filters and alarms for CloudTrail-based detections.

This module is responsible for routing alerts. It does not own every detection source. Some rules and producers are created by other modules and passed into this module as inputs.

---

## What This Module Creates

| Category | Resources |
|---|---|
| Compliance notifications | Compliance SNS topic, compliance SQS queue, SNS-to-SQS subscription, queue policy |
| Security notifications | Security notifications SNS topic, email subscriptions, security notifications SQS queue, security notifications SQS DLQ |
| EventBridge failure handling | Shared EventBridge DLQ for EventBridge-to-security-SNS delivery failures |
| EventBridge targets | Security Hub high/critical SNS target, break-glass SNS target |
| CloudWatch detections | Metric filters and alarms for root activity, unauthorized API calls, CloudTrail stop/delete activity, and IAM policy changes |
| DLQ alerting | CloudWatch alarms for security notification DLQ messages and EventBridge security notification DLQ messages |

---

## Design Purpose

The monitoring module centralizes security and compliance notification handling.

It supports:

- SecOps email alerting for high-priority security events
- Durable SQS-backed notification paths for compliance and security notifications
- EventBridge delivery failure retention for security notification targets
- Alarmed DLQ paths for failed or undelivered security notification events
- CloudTrail-based detection for high-risk account activity
- Notification routing for Security Hub, tamper detection, break-glass access, CloudWatch alarms, and security automation workflows

The module is intentionally focused on notification routing and operational visibility. Security services, automation workflows, and some EventBridge rules are created by other modules and integrated here through variables.

---

## Notification Resources

### Compliance SNS Topic

Creates an encrypted compliance notification SNS topic.

| Attribute | Value |
|---|---|
| Terraform resource | `aws_sns_topic.compliance` |
| Name format | `<name_prefix>-compliance-notifications` |
| Encryption | `var.logs_cmk_arn` |
| Primary producer | AWS Config |

The compliance SNS topic is intended for compliance-oriented notifications, such as AWS Config events.

### Compliance SQS Queue

Creates an encrypted compliance SQS queue subscribed to the compliance SNS topic.

| Attribute | Value |
|---|---|
| Terraform resource | `aws_sqs_queue.compliance` |
| Name format | `<name_prefix>-compliance-queue` |
| Encryption | `var.logs_cmk_arn` |
| Message retention | 14 days |
| Producer | Compliance SNS topic |

The compliance queue is a durable notification subscriber. It can be used for inspection, replay, evidence collection, or future downstream integrations.

The queue is not required to have an active consumer in the baseline. If no consumer is configured, visible messages may accumulate until retention expires or the queue is manually drained.

### Security Notifications SNS Topic

Creates the primary security notification SNS topic.

| Attribute | Value |
|---|---|
| Terraform resource | `aws_sns_topic.secops` |
| Name format | `<name_prefix>-security-notifications` |
| Encryption | `var.logs_cmk_arn` |
| Main consumers | SecOps email subscriptions, security notifications SQS queue |

The security notifications topic receives alerts from:

- CloudWatch alarms
- EventBridge rules
- Security Hub high/critical routing
- Break-glass role usage detection
- Tamper detection routing
- Security automation workflows, where permitted by topic policy

### SecOps Email Subscriptions

Creates email subscriptions for each address in `var.secops_emails`.

| Attribute | Value |
|---|---|
| Terraform resource | `aws_sns_topic_subscription.secops` |
| Protocol | `email` |
| Destination | Each configured SecOps email address |

Email subscriptions must be confirmed by the recipient before alerts are delivered.

### Security Notifications SQS Queue

Creates an encrypted SQS queue subscribed to the security notifications SNS topic.

| Attribute | Value |
|---|---|
| Terraform resource | `aws_sqs_queue.security_notifications` |
| Name format | `<name_prefix>-security-notifications-queue` |
| Encryption | `var.logs_cmk_arn` |
| Message retention | 14 days |
| SNS subscription | Security notifications SNS topic |
| Redrive target | Security notifications DLQ |
| Max receive count | 5 |

This queue provides a durable, machine-readable copy of security notifications for future SIEM ingestion, ticketing, replay, evidence collection, or client-owned consumers.

### Security Notifications SQS DLQ

Creates a DLQ for the security notifications SQS queue.

| Attribute | Value |
|---|---|
| Terraform resource | `aws_sqs_queue.security_notifications_dlq` |
| Name format | `<name_prefix>-security-notifications-dlq` |
| Encryption | `var.logs_cmk_arn` |
| Message retention | 14 days |
| Failure path covered | Messages that reached the security notifications SQS queue but failed downstream processing repeatedly |

A CloudWatch alarm notifies SecOps when messages are visible in this DLQ.

### Security Notifications EventBridge DLQ

Creates a shared EventBridge DLQ for failed EventBridge delivery to the security notifications SNS topic.

| Attribute | Value |
|---|---|
| Terraform resource | `aws_sqs_queue.security_notifications_eventbridge_dlq` |
| Name format | `<name_prefix>-security-notifications-eventbridge-dlq` |
| Encryption | `var.logs_cmk_arn` |
| Message retention | 14 days |
| Failure path covered | EventBridge failed to deliver a security notification event to the security notifications SNS topic |

This DLQ is used by EventBridge targets that send security alerts to the security notifications SNS topic.

Current protected SNS targets include:

- Security Hub high/critical findings to security notifications SNS
- Break-glass role assumption alerts to security notifications SNS
- Tamper detection alerts to security notifications SNS

A CloudWatch alarm notifies SecOps when messages are visible in this EventBridge DLQ.

---

## DLQ Model

The module uses two different DLQ patterns for security notifications.

| DLQ | Covers | Example failure |
|---|---|---|
| `security-notifications-eventbridge-dlq` | EventBridge could not deliver an event to the security notifications SNS topic | EventBridge target delivery to SNS failed after retries |
| `security-notifications-dlq` | A message reached the security notifications SQS queue but failed downstream processing repeatedly | A future queue consumer fails to process the same message more than 5 times |

These queues protect different delivery edges and should not be merged.

High-level flow:

```text
EventBridge Rule
    |
    v
Security Notifications SNS Topic
    |
    +--> SecOps Email Subscriptions
    |
    +--> Security Notifications SQS Queue
            |
            v
        Security Notifications SQS DLQ

If EventBridge cannot deliver to SNS:

EventBridge Rule
    |
    v
Security Notifications EventBridge DLQ
```

---

## EventBridge Targets

### Security Hub High/Critical Findings

Creates an EventBridge target that sends high and critical Security Hub findings to the security notifications SNS topic.

| Attribute | Value |
|---|---|
| Terraform resource | `aws_cloudwatch_event_target.securityhub_high_critical` |
| Rule owner | Automation module |
| Rule name input | `var.securityhub_high_critical_rule_name` |
| Rule ARN input | `var.securityhub_high_critical_rule_arn` |
| Target ID | `sec-hub-to-secops-sns` |
| Target ARN | `aws_sns_topic.secops.arn` |
| DLQ | `aws_sqs_queue.security_notifications_eventbridge_dlq.arn` |
| Retry attempts | 3 |
| Max event age | 3600 seconds |

The target uses an input transformer to produce a human-readable alert message with finding severity, title, product, account, region, workflow status, record state, and affected resource details.

### Break-Glass Role Usage

Creates an EventBridge rule and SNS target for break-glass role assumption events.

| Attribute | Value |
|---|---|
| EventBridge rule | `aws_cloudwatch_event_rule.break_glass_assumed` |
| Target | `aws_cloudwatch_event_target.break_glass_assumed_to_sns` |
| Rule name format | `<name_prefix>-break-glass-admin-assumed` |
| Target ID | `break-glass-to-secops-sns` |
| Target ARN | `aws_sns_topic.secops.arn` |
| DLQ | `aws_sqs_queue.security_notifications_eventbridge_dlq.arn` |
| Retry attempts | 3 |
| Max event age | 3600 seconds |

The rule matches CloudTrail events for `sts.amazonaws.com` `AssumeRole` activity where the requested role ARN matches `var.break_glass_admin_role_arn`.

Break-glass usage should be treated as critical unless it is tied to an approved emergency.

### Tamper Detection Alerts

The tamper detection EventBridge rule is created outside this module and passed in through `var.tamper_detection_rule_arn`.

The monitoring module authorizes that rule to publish to the security notifications SNS topic and allows it to use the shared security notifications EventBridge DLQ.

---

## CloudWatch Metric Filters and Alarms

The module creates CloudWatch Log Metric Filters against the CloudTrail CloudWatch Log Group provided through `var.cloudtrail_logs_group_name`.

| Detection | Metric filter | Metric name | Alarm name format |
|---|---|---|---|
| Root activity | `RootActivity` | `RootActivityCount` | `<name_prefix>-Root-User-Activity` |
| Unauthorized API calls | `Unauthorized-API-Calls` | `UnauthorizedAPICallCount` | `<name_prefix>-Unauthorized_API_Calls` |
| CloudTrail stop/delete activity | `CloudTrail-Disabled` | `CloudTrailDisabled` | `<name_prefix>-CloudTrailDisabled` |
| IAM policy changes | `IamPolicyChanges` | `IamPolicyChanges` | `<name_prefix>-IamPolicyChanges` |

All of these alarms route to the security notifications SNS topic.

### Root Activity

Detects root user activity.

Root activity should be rare and reviewed whenever it occurs.

### Unauthorized API Calls

Detects `UnauthorizedOperation` and `AccessDenied` API errors.

This can indicate suspicious enumeration, failed privilege attempts, misconfigured roles, or normal least-privilege tuning events.

### CloudTrail Disabled

Detects `StopLogging` and `DeleteTrail` events.

This is a high-priority alert because CloudTrail tampering can indicate attempted defense evasion.

### IAM Policy Changes

Detects selected IAM policy and role trust policy changes, including:

- `CreatePolicy`
- `PutRolePolicy`
- `AttachRolePolicy`
- `DeletePolicy`
- `DetachRolePolicy`
- `UpdateAssumeRolePolicy`

These events may indicate privilege creation, privilege expansion, permission removal, cleanup activity, or trust policy changes that affect who can assume a role.

---

## DLQ Alarms

### Security Notifications SQS DLQ Alarm

Creates an alarm for messages visible in the security notifications SQS DLQ.

| Attribute | Value |
|---|---|
| Terraform resource | `aws_cloudwatch_metric_alarm.security_notifications_dlq_visible_messages` |
| Alarm name format | `<name_prefix>-security-notifications-dlq-visible-messages` |
| Namespace | `AWS/SQS` |
| Metric | `ApproximateNumberOfMessagesVisible` |
| Statistic | `Maximum` |
| Period | 300 seconds |
| Alarm action | Security notifications SNS topic |

This alarm indicates that a message reached the security notifications SQS queue but was repeatedly not processed successfully by a consumer.

### Security Notifications EventBridge DLQ Alarm

Creates an alarm for messages visible in the security notifications EventBridge DLQ.

| Attribute | Value |
|---|---|
| Terraform resource | `aws_cloudwatch_metric_alarm.security_notifications_eventbridge_dlq_messages` |
| Alarm name format | `<name_prefix>-Security-Notifications-EventBridge-DLQ-Messages` |
| Namespace | `AWS/SQS` |
| Metric | `ApproximateNumberOfMessagesVisible` |
| Statistic | `Maximum` |
| Period | 300 seconds |
| Alarm action | Security notifications SNS topic |

This alarm indicates that EventBridge failed to deliver one or more security notification events to the security notifications SNS topic after retry handling.

---

## Inputs

| Name | Description | Required |
|---|---|---:|
| `name_prefix` | Prefix used for resource names and CloudWatch metric namespace | Yes |
| `environment` | Environment name, such as `dev`, `staging`, or `prod` | Yes |
| `logs_cmk_arn` | KMS CMK ARN used to encrypt SNS topics and SQS queues | Yes |
| `cloudtrail_logs_group_name` | CloudWatch Log Group name where CloudTrail events are delivered | Yes |
| `secops_emails` | List of email addresses subscribed to SecOps notifications | Yes |
| `tamper_detection_rule_arn` | ARN of the tamper detection EventBridge rule | Yes |
| `account_id` | AWS account ID used in SNS topic policy conditions | Yes |
| `lambda_ip_enrichment_role_arn` | IAM role ARN for the IP Enrichment Lambda | Yes |
| `lambda_ec2_isolation_role_arn` | IAM role ARN for the EC2 Isolation Lambda | Yes |
| `lambda_ec2_rollback_role_arn` | IAM role ARN for the EC2 Rollback Lambda | Yes |
| `break_glass_admin_role_arn` | IAM role ARN for the break-glass admin role | Yes |
| `securityhub_high_critical_rule_name` | Name of the EventBridge rule for high/critical Security Hub findings | Yes |
| `securityhub_high_critical_rule_arn` | ARN of the EventBridge rule for high/critical Security Hub findings | Yes |

---

## Outputs

| Name | Description |
|---|---|
| `compliance_topic_arn` | ARN of the compliance SNS topic |
| `secops_topic_arn` | ARN of the security notifications SNS topic |
| `sec_notifs_eventbridge_dlq_arn` | ARN of the shared EventBridge DLQ for security notification target failures |

---

## Usage Example

```hcl
module "monitoring" {
  source = "../modules/monitoring"

  name_prefix                         = local.name_prefix
  environment                         = var.environment
  account_id                          = data.aws_caller_identity.current.account_id

  cloudtrail_logs_group_name          = module.logging.cloudtrail_logs_group_name
  logs_cmk_arn                        = module.security.logs_cmk_arn
  tamper_detection_rule_arn           = module.security.tamper_detection_rule_arn
  securityhub_high_critical_rule_arn  = module.automation.securityhub_high_critical_rule_arn
  securityhub_high_critical_rule_name = module.automation.securityhub_high_critical_rule_name

  lambda_ip_enrichment_role_arn       = module.iam.lambda_ip_enrichment_role_arn
  lambda_ec2_isolation_role_arn       = module.iam.lambda_ec2_isolation_role_arn
  lambda_ec2_rollback_role_arn        = module.iam.lambda_ec2_rollback_role_arn
  break_glass_admin_role_arn          = module.iam.break_glass_admin_role_arn

  secops_emails                       = var.secops_emails
}
```

---

## Validation

Use the automated validation scripts for normal validation.

```bash
./scripts/validation/validate-sns.sh dev
./scripts/validation/validate-sqs.sh dev
./scripts/validation/validate-eventbridge.sh dev
```

Expected coverage:

| Script | Main checks |
|---|---|
| `validate-sns.sh` | Security and compliance SNS topics, encryption, subscription counts, pending confirmations |
| `validate-sqs.sh` | Compliance queue, security notification queue, security notification DLQ, security notification EventBridge DLQ, encryption, SNS-to-SQS wiring |
| `validate-eventbridge.sh` | EventBridge rules, targets, target DLQs, retry policies, Security Hub/SecOps routing |

Detailed manual validation commands belong in the validation runbook rather than this module README.

Recommended companion doc path:

```text
docs/validation/monitoring-validation.md
```

---

## Alert Routing Summary

### Compliance Notification Path

```text
AWS Config
    |
    v
Compliance SNS Topic
    |
    v
Compliance SQS Queue
```

### Security Notification Path

```text
CloudWatch Alarms / EventBridge Rules / Lambda Publishers
    |
    v
Security Notifications SNS Topic
    |
    +--> SecOps Email Subscriptions
    |
    +--> Security Notifications SQS Queue
```

### Security Hub High/Critical Path

```text
Security Hub Finding
    |
    v
EventBridge Rule from automation module
    |
    +--> IP Enrichment Lambda target from automation module
    |
    +--> Security Notifications SNS target from monitoring module
```

### Break-Glass Notification Path

```text
STS AssumeRole API Call
    |
    v
CloudTrail Event
    |
    v
EventBridge Rule
    |
    v
Security Notifications SNS Topic
```

### EventBridge Security Notification Failure Path

```text
EventBridge Rule
    |
    v
Security Notifications SNS Target
    |
    x delivery failure after retries
    |
    v
Security Notifications EventBridge DLQ
    |
    v
CloudWatch Alarm to Security Notifications SNS
```

---

## Operational Notes

### Email Confirmation

SNS email subscriptions remain pending until each recipient confirms the subscription.

A pending email subscription means that recipient will not receive alerts.

### CloudTrail Dependency

The CloudWatch metric filters require CloudTrail events to be delivered to the CloudWatch Log Group passed through `var.cloudtrail_logs_group_name`.

If CloudTrail is not delivering to that log group, root activity, unauthorized API call, CloudTrail disabled, and IAM policy change alarms will not receive matching events.

### KMS Dependency

SNS topics and SQS queues are encrypted with the logs CMK.

If notifications are not delivered, check both resource policies and KMS permissions for the services involved, including SNS, SQS, CloudWatch, EventBridge, AWS Config, and authorized Lambda publishers.

### DLQ Handling

DLQ messages are not automatically replayed by this module.

A visible message in a security notification DLQ should be treated as an operational signal requiring review. Operators should inspect the message, identify the failed delivery or processing path, fix the underlying issue, and then decide whether manual replay or archival is appropriate.

Recommended companion runbook path:

```text
docs/runbooks/notification-dlq-response.md
```

---

## Troubleshooting

### SecOps Emails Are Not Receiving Alerts

Check:

- Email subscriptions are confirmed
- Security notifications SNS topic exists
- SNS topic policy allows the publishing service or rule
- The event, alarm, or Lambda publisher actually fired
- KMS permissions allow the service to use the logs CMK
- The recipient email did not filter the message as spam

### Security Notifications Queue Is Not Receiving Messages

Check:

- Security notifications SNS topic exists
- Security notifications SQS queue exists
- SNS subscription exists from the topic to the queue
- SQS queue policy allows the security notifications SNS topic to send messages
- KMS permissions allow SNS and SQS to use the logs CMK

### EventBridge Security Notification DLQ Has Messages

This means EventBridge could not deliver one or more security notification events to the security notifications SNS topic.

Check:

- The affected EventBridge target exists and points to the security notifications SNS topic
- The target has the expected retry policy and DLQ configuration
- The SNS topic policy allows the relevant EventBridge rule ARN to publish
- KMS permissions allow EventBridge/SNS/SQS to use the encrypted resources where required
- The EventBridge DLQ policy allows the expected rule ARN to send messages

### Security Notifications SQS DLQ Has Messages

This means a message reached the security notifications SQS queue but was repeatedly not processed successfully by a consumer.

Check:

- The downstream consumer, if configured, is healthy
- The message format is expected by the consumer
- The queue redrive policy is configured correctly
- The failure is not caused by permissions, timeout, throttling, or malformed input

### CloudWatch Alarms Do Not Fire

Check:

- CloudTrail is sending logs to the expected log group
- Metric filters exist on the correct log group
- Matching events occurred after the filter was created
- Alarm actions point to the security notifications SNS topic
- SNS/KMS policies allow delivery

---

## Security Notes

- SNS topics are encrypted with the logs CMK.
- SQS queues and DLQs are encrypted with the logs CMK.
- Security notification delivery uses both email and durable SQS fanout.
- EventBridge security notification targets use retry policies and DLQ handling.
- DLQ alarms route to the security notifications SNS topic.
- SNS topic publishing is restricted through topic policy statements.
- SQS queue writes are restricted to expected SNS topics or EventBridge rules.
- Break-glass role usage generates a critical alert.
- Root user activity generates an alert.
- Unauthorized API calls generate an alert.
- CloudTrail stop/delete activity generates an alert.
- Selected IAM policy changes generate an alert.

---

## Design Principles

This module follows:

- Centralized security alerting
- Encrypted notification paths
- Durable notification delivery
- Event-driven monitoring
- Alarmed failure retention
- Least privilege publishing
- Human-readable security notifications
- Separation of detection and notification routing
- Fast escalation for critical security events

---

## Notes

- Deploy this module after logging resources exist.
- The CloudTrail CloudWatch Log Group must exist before metric filters can be attached.
- The logs CMK must allow required AWS services to use encrypted SNS/SQS resources.
- The Security Hub high/critical EventBridge rule is created outside this module.
- The tamper detection EventBridge rule is created outside this module.
- The security notifications SNS topic ARN is consumed by automation and security workflows.
- The compliance SNS topic ARN can be consumed by AWS Config or other compliance routing logic.
- For production, confirm all SecOps email subscriptions after deployment.