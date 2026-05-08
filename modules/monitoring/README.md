# Monitoring Module

## Overview

The `monitoring` module provisions security and compliance notification resources for the environment.

This includes:

- A compliance SNS topic
- A compliance SQS queue
- A SecOps SNS topic
- Email subscriptions for SecOps notifications
- SNS topic policies for AWS service and Lambda publishing
- EventBridge targets for Security Hub high/critical findings
- EventBridge detection for break-glass role usage
- CloudWatch Log Metric Filters for CloudTrail-based detection
- CloudWatch Alarms routed to SecOps notifications

This module acts as the alert routing layer for the baseline.

---

## Purpose

The purpose of this module is to centralize operational and security notifications.

It supports:

- Security alert delivery to SecOps email recipients
- Compliance notification routing through SNS and SQS
- Alerting on high-risk AWS account activity
- Alerting on Security Hub high and critical findings
- Alerting on break-glass role usage
- Alerting on root account activity
- Alerting on unauthorized API calls
- Alerting on CloudTrail tampering
- Alerting on IAM policy changes

This module does not create all detection sources by itself.

Instead, it connects existing detection sources, CloudTrail logs, EventBridge rules, and AWS service events to actionable notification targets.

---

## Resources Created

### Compliance SNS Topic

Creates a compliance notification SNS topic:

```hcl
resource "aws_sns_topic" "compliance"
```

Topic name format:

```text
<name_prefix>-compliance-notifications
```

The topic is encrypted with the logs CMK:

```hcl
kms_master_key_id = var.logs_cmk_arn
```

This topic is intended for AWS Config and compliance-related notifications.

---

### Compliance SNS Topic Policy

Creates a topic policy for the compliance SNS topic:

```hcl
resource "aws_sns_topic_policy" "compliance"
```

The policy allows:

- Account root administration
- AWS Config to publish compliance notifications

The AWS Config service principal is:

```text
config.amazonaws.com
```

---

### Compliance SQS Queue

Creates a compliance SQS queue:

```hcl
resource "aws_sqs_queue" "compliance"
```

Queue name format:

```text
<name_prefix>-compliance-queue
```

The queue is encrypted with the logs CMK:

```hcl
kms_master_key_id = var.logs_cmk_arn
```

This queue receives messages from the compliance SNS topic.

---

### Compliance SNS Subscription

Subscribes the compliance SQS queue to the compliance SNS topic:

```hcl
resource "aws_sns_topic_subscription" "compliance"
```

Subscription protocol:

```text
sqs
```

This allows compliance notifications published to SNS to be delivered into the SQS queue.

---

### Compliance SQS Queue Policy

Creates an SQS queue policy that allows the compliance SNS topic to send messages to the queue:

```hcl
data "aws_iam_policy_document" "compliance_queue_policy"
resource "aws_sqs_queue_policy" "compliance"
```

The policy allows:

```text
sqs:SendMessage
```

Only from the compliance SNS topic ARN.

This prevents unrelated SNS topics or principals from writing to the compliance queue.

---

### SecOps SNS Topic

Creates the main SecOps notification SNS topic:

```hcl
resource "aws_sns_topic" "secops"
```

Topic name format:

```text
<name_prefix>-security-notifications
```

The topic is encrypted with the logs CMK:

```hcl
kms_master_key_id = var.logs_cmk_arn
```

This topic receives security notifications from:

- CloudWatch alarms
- EventBridge rules
- Security Hub event routing
- Tamper detection
- Break-glass detection
- EC2 Isolation Lambda
- EC2 Rollback Lambda
- IP Enrichment Lambda

---

### SecOps SNS Topic Policy

Creates a topic policy for the SecOps SNS topic:

```hcl
resource "aws_sns_topic_policy" "secops"
```

The policy allows publishing from:

| Principal | Purpose |
|---|---|
| Account root | Topic administration |
| `cloudwatch.amazonaws.com` | CloudWatch alarm notifications |
| `events.amazonaws.com` | EventBridge rule notifications |
| IP Enrichment Lambda role | Threat intel enrichment alerts |
| EC2 Isolation Lambda role | Instance isolation alerts |
| EC2 Rollback Lambda role | Instance rollback alerts |
| Break-glass EventBridge rule | Break-glass role usage alerts |
| Tamper detection EventBridge rule | Security service tampering alerts |
| Security Hub high/critical rule | High and critical finding alerts |

EventBridge permissions are scoped with source account and source ARN conditions where applicable.

---

### SecOps Email Subscriptions

Creates email subscriptions for each address in the `secops_emails` variable:

```hcl
resource "aws_sns_topic_subscription" "secops"
```

The module uses:

```hcl
for_each = toset(var.secops_emails)
```

Each email address receives a subscription to the SecOps SNS topic.

Important:

Email subscriptions require confirmation by the recipient before notifications are delivered.

---

### Security Hub High/Critical EventBridge Target

Creates an EventBridge target that sends high and critical Security Hub findings to the SecOps SNS topic:

```hcl
resource "aws_cloudwatch_event_target" "securityhub_high_critical"
```

Important:

The EventBridge rule itself is created outside this module, in the automation layer.

This module receives the rule name and rule ARN through variables:

```hcl
var.securityhub_high_critical_rule_name
var.securityhub_high_critical_rule_arn
```

The target uses an input transformer to format Security Hub findings into readable alert messages.

The alert includes:

- Severity
- Product name
- Finding title
- Time
- Account
- Region
- Finding ID
- Workflow status
- Record state
- Resource type
- Resource ID

---

### Break-Glass Role Assumption Detection Rule

Creates an EventBridge rule that detects when the break-glass admin role is assumed:

```hcl
resource "aws_cloudwatch_event_rule" "break_glass_assumed"
```

The rule matches CloudTrail events for:

```text
eventSource = sts.amazonaws.com
eventName   = AssumeRole
roleArn     = var.break_glass_admin_role_arn
```

This is intended to alert whenever emergency administrative access is used.

---

### Break-Glass EventBridge Target

Creates an EventBridge target that sends break-glass role assumption alerts to the SecOps SNS topic:

```hcl
resource "aws_cloudwatch_event_target" "break_glass_assumed_to_sns"
```

The alert includes:

- Time
- Account
- Region
- Caller ARN
- Role ARN
- Session name
- Source IP
- User agent

Break-glass role usage should be treated as critical and reviewed immediately.

---

## CloudWatch Log Metric Filters and Alarms

The module creates several CloudWatch Log Metric Filters based on the CloudTrail log group.

The CloudTrail log group name is passed in through:

```hcl
var.cloudtrail_logs_group_name
```

Each metric filter creates a custom metric in the namespace:

```hcl
var.name_prefix
```

Each related alarm sends notifications to the SecOps SNS topic.

---

### Root Activity Detection

Creates a metric filter for root user activity:

```hcl
resource "aws_cloudwatch_log_metric_filter" "root_activity"
resource "aws_cloudwatch_metric_alarm" "root_activity"
```

Filter pattern:

```text
{$.userIdentity.type = "Root"}
```

Metric name:

```text
RootActivityCount
```

Alarm name format:

```text
<name_prefix>-Root-User-Activity
```

Expected behavior:

- Any root user activity creates a metric value.
- The alarm triggers when root activity count is greater than or equal to 1 within a 5-minute period.

Root account usage should be rare and should be reviewed.

---

### Unauthorized API Call Detection

Creates a metric filter for unauthorized API activity:

```hcl
resource "aws_cloudwatch_log_metric_filter" "unauthorized_api_calls"
resource "aws_cloudwatch_metric_alarm" "unauthorized_api_calls"
```

Filter pattern detects:

```text
UnauthorizedOperation
AccessDenied
```

Metric name:

```text
UnauthorizedAPICallCount
```

Alarm name format:

```text
<name_prefix>-Unauthorized_API_Calls
```

Expected behavior:

- Any denied API call creates a metric value.
- The alarm triggers when unauthorized API call count is greater than or equal to 1 within a 5-minute period.

This is useful for detecting misconfigured roles, suspicious enumeration, failed privilege attempts, or normal least-privilege tuning events.

---

### CloudTrail Disabled Detection

Creates a metric filter for CloudTrail tampering events:

```hcl
resource "aws_cloudwatch_log_metric_filter" "cloudtrail_disabled"
resource "aws_cloudwatch_metric_alarm" "cloudtrail_disabled"
```

Filter pattern detects:

```text
StopLogging
DeleteTrail
```

Metric name:

```text
CloudTrailDisabled
```

Alarm name format:

```text
<name_prefix>-CloudTrailDisabled
```

Expected behavior:

- Attempts to stop or delete CloudTrail create a metric value.
- The alarm triggers when the count is greater than or equal to 1 within a 5-minute period.

This is a high-priority security alert.

---

### IAM Policy Change Detection

Creates a metric filter for selected IAM policy and role trust policy changes:

```hcl
resource "aws_cloudwatch_log_metric_filter" "iam_policy_changes"
resource "aws_cloudwatch_metric_alarm" "iam_changes"
```

Current filter detects:

```text
CreatePolicy
PutRolePolicy
AttachRolePolicy
DeletePolicy
DetachRolePolicy
UpdateAssumeRolePolicy
```

Metric name:

```text
IamPolicyChanges
```

Alarm name format:

```text
<name_prefix>-IamPolicyChanges
```

Expected behavior:

- Selected IAM policy changes create a metric value.
- Selected IAM policy detach/delete events create a metric value.
- Role trust policy updates create a metric value.
- The alarm triggers when IAM policy change count is greater than or equal to 1 within a 5-minute period.

Security relevance:

- `CreatePolicy`, `PutRolePolicy`, and `AttachRolePolicy` may indicate privilege creation, privilege expansion, or policy attachment activity.
- `DeletePolicy` and `DetachRolePolicy` may indicate attempted permission removal, cleanup, or defense evasion.
- `UpdateAssumeRolePolicy` is especially important because it changes who can assume a role, which can create privilege escalation or persistence risk.

---

## Inputs

| Name | Description | Required |
|---|---|---:|
| `name_prefix` | Prefix used for resource naming and CloudWatch metric namespace | Yes |
| `environment` | Environment name, such as `dev`, `staging`, or `prod` | Yes |
| `logs_cmk_arn` | KMS CMK ARN used to encrypt SNS topics and SQS queue | Yes |
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
| `secops_topic_arn` | ARN of the SecOps SNS topic |

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

### Confirm SNS Topics Exist

```bash
aws sns list-topics \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'Topics[?contains(TopicArn, `security-notifications`) || contains(TopicArn, `compliance-notifications`)].TopicArn' \
  --output table
```

Expected:

- SecOps SNS topic exists
- Compliance SNS topic exists

---

### Confirm SecOps SNS Topic Attributes

```bash
aws sns get-topic-attributes \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --topic-arn "${SECOPS_TOPIC_ARN}" \
  --query 'Attributes.{TopicArn:TopicArn,KmsMasterKeyId:KmsMasterKeyId,DisplayName:DisplayName}' \
  --output table
```

Expected:

- Topic ARN matches the SecOps topic
- KMS master key is configured

---

### Confirm Compliance SNS Topic Attributes

```bash
aws sns get-topic-attributes \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --topic-arn "${COMPLIANCE_TOPIC_ARN}" \
  --query 'Attributes.{TopicArn:TopicArn,KmsMasterKeyId:KmsMasterKeyId,DisplayName:DisplayName}' \
  --output table
```

Expected:

- Topic ARN matches the compliance topic
- KMS master key is configured

---

### Confirm SecOps Email Subscriptions

```bash
aws sns list-subscriptions-by-topic \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --topic-arn "${SECOPS_TOPIC_ARN}" \
  --query 'Subscriptions[].[Protocol,Endpoint,SubscriptionArn]' \
  --output table
```

Expected:

- Each configured SecOps email address appears as an email subscription
- Confirmed subscriptions show a real subscription ARN
- Unconfirmed subscriptions show `PendingConfirmation`

Important:

Email recipients must confirm the SNS subscription before alerts are delivered.

---

### Confirm Compliance Queue Exists

```bash
aws sqs list-queues \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --queue-name-prefix "${NAME_PREFIX}-compliance-queue" \
  --output table
```

Expected:

- Compliance queue URL is returned

---

### Confirm Compliance Queue Encryption

```bash
aws sqs get-queue-attributes \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --queue-url "${COMPLIANCE_QUEUE_URL}" \
  --attribute-names KmsMasterKeyId \
  --query 'Attributes' \
  --output table
```

Expected:

- `KmsMasterKeyId` is configured
- KMS key matches the logs CMK

---

### Confirm Compliance SNS to SQS Subscription

```bash
aws sns list-subscriptions-by-topic \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --topic-arn "${COMPLIANCE_TOPIC_ARN}" \
  --query 'Subscriptions[].[Protocol,Endpoint,SubscriptionArn]' \
  --output table
```

Expected:

- Protocol is `sqs`
- Endpoint is the compliance queue ARN

---

### Confirm Break-Glass EventBridge Rule

```bash
aws events describe-rule \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --name "${NAME_PREFIX}-break-glass-admin-assumed"
```

Expected:

- Rule exists
- Rule state is `ENABLED`
- Event pattern matches STS `AssumeRole` activity for the break-glass role

---

### Confirm Break-Glass EventBridge Target

```bash
aws events list-targets-by-rule \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --rule "${NAME_PREFIX}-break-glass-admin-assumed" \
  --query 'Targets[].[Id,Arn]' \
  --output table
```

Expected:

- Target ID is `break-glass-to-secops-sns`
- Target ARN is the SecOps SNS topic ARN

---

### Confirm Security Hub High/Critical EventBridge Target

```bash
aws events list-targets-by-rule \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --rule "${SECURITYHUB_HIGH_CRITICAL_RULE_NAME}" \
  --query 'Targets[].[Id,Arn]' \
  --output table
```

Expected:

- Target ID is `sec-hub-to-secops-sns`
- Target ARN is the SecOps SNS topic ARN

---

### Confirm CloudWatch Metric Filters

```bash
aws logs describe-metric-filters \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --log-group-name "${CLOUDTRAIL_LOG_GROUP_NAME}" \
  --query 'metricFilters[].[filterName,filterPattern,metricTransformations[0].metricName]' \
  --output table
```

Expected metric filters include:

- `RootActivity`
- `Unauthorized-API-Calls`
- `CloudTrail-Disabled`
- `IamPolicyChanges`

---

### Confirm CloudWatch Alarms

```bash
aws cloudwatch describe-alarms \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --alarm-name-prefix "${NAME_PREFIX}" \
  --query 'MetricAlarms[].[AlarmName,StateValue,MetricName,Namespace]' \
  --output table
```

Expected alarms include:

- `<name_prefix>-Root-User-Activity`
- `<name_prefix>-Unauthorized_API_Calls`
- `<name_prefix>-CloudTrailDisabled`
- `<name_prefix>-IamPolicyChanges`

---

## Alert Routing

### Compliance Notification Path

Compliance notifications follow this path:

```text
AWS Config
    |
    v
Compliance SNS Topic
    |
    v
Compliance SQS Queue
```

This allows compliance events to be queued for later processing, inspection, or integration with another system.

---

### Security Notification Path

Security notifications follow this path:

```text
CloudWatch Alarms / EventBridge Rules / Lambda Functions
    |
    v
SecOps SNS Topic
    |
    v
SecOps Email Subscriptions
```

This supports direct human notification for high-priority security events.

---

### Security Hub Notification Path

Security Hub high and critical findings follow this path:

```text
Security Hub Finding
    |
    v
EventBridge Rule from automation module
    |
    v
EventBridge Target from monitoring module
    |
    v
SecOps SNS Topic
    |
    v
SecOps Email Subscriptions
```

The rule is created in the automation module.

The target is created in this monitoring module.

---

### Break-Glass Notification Path

Break-glass role usage follows this path:

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
SecOps SNS Topic
    |
    v
SecOps Email Subscriptions
```

Break-glass usage should be investigated immediately unless it is tied to a known approved emergency.

---

## Operational Considerations

### Email Subscription Confirmation

SNS email subscriptions do not become active until the recipient confirms the subscription.

After deploying this module, each address in the `secops_emails` variable should receive a confirmation email.

Until confirmed, the subscription remains in:

```text
PendingConfirmation
```

Alerts will not be delivered to that recipient until confirmation is complete.

---

### CloudTrail Log Dependency

Several detections depend on CloudTrail events being delivered to CloudWatch Logs.

The following detections require a working CloudTrail log group:

- Root activity
- Unauthorized API calls
- CloudTrail disabled events
- IAM policy changes

If CloudTrail is not delivering to the expected log group, these metric filters and alarms will not receive data.

---

### KMS Encryption

SNS topics and the SQS queue use the logs CMK.

The logs CMK policy must allow the relevant AWS services to use the key where required.

Services involved may include:

- SNS
- SQS
- CloudWatch
- EventBridge
- AWS Config
- Lambda publishers

If alerts are not being delivered, KMS permissions should be checked along with SNS topic policies.

---

### Security Hub Rule Location

The Security Hub high/critical EventBridge rule is not created in this module.

It is expected to be created elsewhere and passed into this module through:

```hcl
securityhub_high_critical_rule_name
securityhub_high_critical_rule_arn
```

This module only attaches the SecOps SNS topic as a target.

---

### Tamper Detection Rule Location

The tamper detection EventBridge rule is not created in this module.

It is expected to be created by the security module and passed into this module through:

```hcl
tamper_detection_rule_arn
```

The SecOps SNS topic policy allows that rule to publish alerts.

---

## Troubleshooting

### SecOps Emails Are Not Receiving Alerts

Check:

- Email subscriptions are confirmed
- SecOps SNS topic exists
- SNS topic policy allows the publishing service
- The event or alarm actually fired
- The recipient email did not filter the message as spam
- KMS permissions allow SNS to use the configured CMK

Validation command:

```bash
aws sns list-subscriptions-by-topic \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --topic-arn "${SECOPS_TOPIC_ARN}" \
  --query 'Subscriptions[].[Protocol,Endpoint,SubscriptionArn]' \
  --output table
```

---

### Subscription Shows PendingConfirmation

This means the email recipient has not confirmed the SNS subscription.

Fix:

- Open the SNS confirmation email
- Click the confirmation link
- Re-run `list-subscriptions-by-topic`
- Confirm the subscription ARN is no longer `PendingConfirmation`

---

### CloudWatch Alarm Does Not Fire

Check:

- CloudTrail is sending logs to the expected CloudWatch Log Group
- The metric filter exists on the correct log group
- The filter pattern matches the event format
- The matching event actually occurred after the metric filter was created
- The alarm is using the correct metric namespace and metric name
- The alarm action points to the SecOps SNS topic

---

### Metric Filters Are Missing

Check:

- `cloudtrail_logs_group_name` is correct
- The CloudTrail log group exists before this module is applied
- Terraform applied the monitoring module successfully
- The AWS region is correct

Validation command:

```bash
aws logs describe-metric-filters \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --log-group-name "${CLOUDTRAIL_LOG_GROUP_NAME}" \
  --output table
```

---

### Security Hub Findings Are Not Sending SNS Alerts

Check:

- The Security Hub high/critical EventBridge rule exists
- The EventBridge target exists
- The target ARN is the SecOps SNS topic
- The SecOps SNS topic policy allows the rule ARN to publish
- The finding matches the rule pattern
- The finding is active and high or critical severity

Validation command:

```bash
aws events list-targets-by-rule \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --rule "${SECURITYHUB_HIGH_CRITICAL_RULE_NAME}" \
  --output table
```

---

### Break-Glass Alerts Are Not Firing

Check:

- The break-glass role ARN passed to the module is correct
- The role assumption event is recorded by CloudTrail
- The EventBridge rule exists and is enabled
- The EventBridge target points to the SecOps SNS topic
- The SecOps SNS topic policy allows EventBridge to publish from the break-glass rule

Validation command:

```bash
aws events describe-rule \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --name "${NAME_PREFIX}-break-glass-admin-assumed"
```

---

### Compliance Queue Is Not Receiving Messages

Check:

- Compliance SNS topic exists
- Compliance SQS queue exists
- SQS queue policy allows the compliance SNS topic to send messages
- SNS subscription exists from the topic to the queue
- AWS Config is configured to publish to the compliance topic
- KMS permissions allow SNS and SQS to use the logs CMK

Validation command:

```bash
aws sqs get-queue-attributes \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --queue-url "${COMPLIANCE_QUEUE_URL}" \
  --attribute-names All
```

---

## Security Notes

- SNS topics are encrypted with the logs CMK.
- The compliance SQS queue is encrypted with the logs CMK.
- SecOps email subscriptions require confirmation.
- SecOps topic publishing is restricted through topic policy statements.
- EventBridge publish permissions are scoped by source account and source ARN where applicable.
- Compliance queue writes are restricted to the compliance SNS topic.
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
- Event-driven monitoring
- Least privilege publishing
- Human-readable security notifications
- Separation of detection and notification routing
- Compliance event queuing
- Fast escalation for critical security events

---

## Notes

- Deploy this module after logging resources exist.
- The CloudTrail CloudWatch Log Group must exist before metric filters can be attached.
- The logs CMK must allow required AWS services to use encrypted SNS/SQS resources.
- The Security Hub high/critical EventBridge rule is created outside this module.
- The tamper detection EventBridge rule is created outside this module.
- The SecOps SNS topic ARN is consumed by automation and security workflows.
- The compliance SNS topic ARN can be consumed by AWS Config or other compliance routing logic.
- For production, confirm all SecOps email subscriptions after deployment.