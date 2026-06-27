# Changelog

## v1.3.1

### Added

- Added a dedicated security notifications SQS queue subscribed to the security notifications SNS topic.
- Added a security notifications SQS DLQ for repeatedly unprocessed security notification messages.
- Added a shared security notifications EventBridge DLQ for failed EventBridge deliveries to the security notifications SNS topic.
- Added a CloudWatch alarm for visible messages in the security notifications EventBridge DLQ.
- Added workflow-specific DLQs for EC2 Isolation, EC2 Rollback, and IP Enrichment automation workflows.
- Added EventBridge target DLQ configuration and retry policies for protected automation and security notification targets.
- Added Lambda asynchronous failure handling for the EC2 Isolation workflow.
- Added CloudWatch DLQ alarms for security automation failure paths.
- Added detailed monitoring validation guidance under `docs/validation/monitoring-validation.md`.
- Added notification DLQ response guidance under `docs/runbooks/notification-dlq-response.md`.

### Changed

- Updated security notification routing to support both human alert delivery and durable SQS-backed message retention.
- Updated EventBridge security notification targets to use retry policies and a shared EventBridge DLQ.
- Updated automation workflows so EventBridge delivery failures are retained in workflow-specific DLQs.
- Updated SQS validation to include compliance, security notification, security notification DLQ, security notification EventBridge DLQ, and security automation DLQ resources.
- Updated EventBridge validation to verify target DLQs, retry policies, expected target ARNs, and expected DLQ ARNs.
- Updated monitoring, automation, security, tamper detection, and root-level documentation to reflect the new notification and DLQ architecture.
- Condensed the monitoring module README and moved detailed validation and response procedures into dedicated documentation under `docs/`.

### Notes

- Workflow DLQs are terminal failure-retention queues intended for SecOps review, troubleshooting, and manual replay or remediation where appropriate.
- The security notifications EventBridge DLQ covers EventBridge-to-SNS delivery failures.
- The security notifications SQS DLQ covers repeated processing failures after messages have already reached the security notifications SQS queue.
- The compliance and security notification queues may accumulate visible messages when no downstream consumer is configured. This is expected when the queues are used as durable notification subscribers.
- The new DLQ hardening improves alert-delivery resilience but does not automatically replay failed security automation or notification events.

## v1.3.0

### Added

- Added validation report export workflow through `scripts/validation/export-report.sh`.
- Added timestamped validation result directories under `validation-results/<environment>/<timestamp>/`.
- Added per-script validation log capture.
- Added generated Markdown validation summaries through `summary.md`.
- Added generated machine-readable validation summaries through `summary.json`.
- Added validation report template under `docs/assurance/validation-report-template.md`.
- Added validation evidence guide under `docs/assurance/validation-evidence-guide.md`.

### Changed

- Updated validation documentation to describe exported validation evidence packages.
- Updated project documentation to position validation reports for client handoff, troubleshooting, and deployment evidence.

### Notes

- Generated validation output is ignored by Git by default.
- Validation reporting is intended to support deployment evidence and audit-readiness discussions.
- Validation reports do not replace formal SOC 2 or ISO 27001 audits, control owner review, policy review, risk assessment, or ISMS activities.