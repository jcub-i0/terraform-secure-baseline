# Tamper Detection Module

## Overview

The `tamper_detection` module creates an EventBridge-based alerting control for detecting attempts to disable, delete, or modify core AWS security services.

When a matching API call is observed through CloudTrail, the module sends a formatted alert to an SNS topic.

---

## Purpose

This module helps detect suspicious changes to security controls such as:

- CloudTrail
- GuardDuty
- Security Hub
- KMS

These events may indicate an attempt to weaken logging, detection, encryption, or security monitoring.

---

## Architecture

```text
AWS API Call
    |
    v
CloudTrail Event
    |
    v
EventBridge Rule
    |
    v
SNS Topic
    |
    v
SecOps Notification
```

---

## Detected Actions

The module monitors for tampering actions including:

### CloudTrail

- `StopLogging`
- `DeleteTrail`
- `UpdateTrail`
- `PutEventSelectors`
- `PutInsightSelectors`

### GuardDuty

- `DeleteDetector`
- `UpdateDetector`
- `DisassociateFromMasterAccount`
- `DisassociateMembers`

### Security Hub

- `DisableSecurityHub`
- `DeleteMembers`
- `DisassociateFromMasterAccount`

### KMS

- `ScheduleKeyDeletion`
- `DisableKey`
- `PutKeyPolicy`
- `UpdateKeyDescription`

---

## Alert Behavior

When a matching event is detected, EventBridge sends a formatted message to the configured SNS topic.

The alert includes:

- Action
- Service
- Time
- AWS account
- Region
- Actor ARN
- Source IP
- MFA status

---

## Usage

```hcl
module "tamper_detection" {
  source = "./tamper_detection"

  name_prefix                    = var.name_prefix
  cloud_name                     = var.cloud_name
  environment                    = var.environment
  secops_topic_arn               = var.secops_topic_arn
  sec_notifs_eventbridge_dlq_arn = var.sec_notifs_eventbridge_dlq_arn
}
```

---

## Inputs

| Name | Description |
|------|-------------|
| `cloud_name` | Name of the cloud environment |
| `environment` | Environment name, such as `dev`, `staging`, or `prod` |
| `name_prefix` | Naming prefix used for created resources |
| `secops_topic_arn` | SNS topic ARN used for tamper alerts |
| `sec_notifs_eventbridge_dlq_arn` | ARN of the 'security_notifications_eventbridge_dlq' DLQ|
  type        = string
}

---

## Outputs

| Name | Description |
|------|-------------|
| `tamper_detection_rule_name` | Name of the EventBridge tamper detection rule |
| `tamper_detection_rule_arn` | ARN of the EventBridge tamper detection rule |

---

## Important Notes

- This module depends on CloudTrail events being available in EventBridge.
- This module does not prevent tampering; it detects and alerts on suspicious activity.
- Alerts should be reviewed by SecOps or platform administrators.
- The SNS topic should be monitored by the appropriate security response team.

---

## Summary

The `tamper_detection` module provides a lightweight but important detection layer for security control changes.

It helps identify attempts to disable or weaken AWS security services and routes those events to SNS for investigation.