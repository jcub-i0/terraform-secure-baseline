# Notification DLQ Response Runbook

## Purpose

This runbook explains how to respond when monitoring-module notification DLQs contain messages.

The monitoring module uses two security notification DLQ patterns:

| Queue | Meaning |
|---|---|
| `security-notifications-eventbridge-dlq` | EventBridge could not deliver a security notification event to the security notifications SNS topic |
| `security-notifications-dlq` | A message reached the security notifications SQS queue but failed downstream processing repeatedly |

These DLQs retain failures for review. They do not automatically replay messages.

---

## Initial Triage

When a DLQ alarm fires:

1. Identify which DLQ has visible messages.
2. Capture the approximate visible and not-visible message counts.
3. Review recent CloudWatch alarm state changes.
4. Inspect one message without deleting it.
5. Determine whether the failure is an EventBridge delivery issue, SNS/SQS policy issue, KMS issue, or downstream consumer issue.

---

## Inspect Queue Counts

```bash
aws sqs get-queue-attributes \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE" \
  --queue-url "$QUEUE_URL" \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible ApproximateAgeOfOldestMessage \
  --output table
```

---

## Inspect a Message Safely

Receive one message with a short visibility timeout.

```bash
aws sqs receive-message \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE" \
  --queue-url "$QUEUE_URL" \
  --max-number-of-messages 1 \
  --visibility-timeout 30 \
  --attribute-names All \
  --message-attribute-names All \
  --output json
```

Do not delete the message until the failure has been understood and the operator has decided whether to replay, archive, or discard it.

---

## EventBridge DLQ Response

Use this path when messages appear in:

```text
<name_prefix>-security-notifications-eventbridge-dlq
```

This means EventBridge could not deliver to the security notifications SNS target.

Check:

- EventBridge target exists and points to the security notifications SNS topic
- EventBridge target has the expected DLQ and retry policy
- Security notifications SNS topic exists
- SNS topic policy allows the source EventBridge rule ARN to publish
- EventBridge DLQ queue policy allows the source EventBridge rule ARN to send messages
- KMS permissions allow encrypted SNS/SQS delivery

Useful command:

```bash
aws events list-targets-by-rule \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE" \
  --event-bus-name default \
  --rule "$RULE_NAME" \
  --query 'Targets[].{Id:Id,Arn:Arn,DLQ:DeadLetterConfig.Arn,MaxAttempts:RetryPolicy.MaximumRetryAttempts,MaxAge:RetryPolicy.MaximumEventAgeInSeconds}' \
  --output table
```

After fixing the delivery issue, decide whether the retained event still needs to be replayed or whether the underlying alert has already been handled through another path.

---

## Security Notifications SQS DLQ Response

Use this path when messages appear in:

```text
<name_prefix>-security-notifications-dlq
```

This means a message reached the security notifications SQS queue and was moved to its DLQ after repeated receive failures.

Check:

- Whether a downstream consumer is configured for the security notifications queue
- Consumer logs, permissions, timeouts, and parsing errors
- Message schema compatibility
- Queue redrive policy and max receive count
- KMS permissions for the consumer

If no consumer is configured, this DLQ should normally remain empty. Messages in the primary security notifications queue can accumulate by design, but messages in the DLQ indicate repeated failed processing by a consumer.

---

## Replay Guidance

Replay should be manual and intentional.

Before replaying:

- Confirm the original failure has been fixed
- Confirm the message still represents an actionable alert
- Confirm replay will not trigger duplicate incident handling or automation side effects
- Preserve evidence if the message is relevant to an incident or audit trail

For notification-only messages, replay may mean publishing a reconstructed alert back to the security notifications SNS topic. For workflow messages, follow the workflow-specific runbook instead of blindly re-sending the raw DLQ payload.

---

## Closure Criteria

A DLQ incident can be closed when:

- The root cause is understood
- The broken delivery or processing path has been fixed
- The message has been replayed, archived, or intentionally discarded
- Queue depth has returned to zero or an accepted baseline
- Alarm state has returned to OK
- Any incident or audit notes have been captured
