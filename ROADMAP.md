# v1.12.0 Roadmap — Application Runtime Extensibility

**Objective:** Enable application-agnostic SaaS workloads to use approved AWS services and report application health through the existing canonical `ecs_services` interface.

**Guardrails:** All new capabilities are opt-in. Preserve existing service configurations, ECS task/execution role separation, immutable image deployments, and Terraform ownership boundaries. No application-specific modules, default privilege expansion, or unnecessary baseline costs.

## Milestone 1 — Extensible ECS Task IAM (Required)

**Work**
- Add optional per-service task-role managed policy ARN attachments to `ecs_services` and propagate them through the existing Terraform modules.
- Attach policies to the **application task role**, never the ECS execution role; keep default task-role permissions empty.
- Extend IAM validation to check exact configured attachments and reject unexpected permissions or attachments.

**Acceptance criteria**
- A reference task can invoke an explicitly authorized AWS API but is denied an ungranted action.
- Existing services without policy attachments have no IAM changes; `image_digest = null` still creates no task roles or attachments.

## Milestone 2 — ECS-Native Container Health Checks (Required)

**Work**
- Add an optional per-service `health_check` configuration (command, interval, timeout, retries, start period).
- Render the check in the ECS task definition and extend runtime validation for configuration and live container health.
- Preserve independent ALB target-health behavior and existing defaults when disabled.

**Acceptance criteria**
- A reference application with an enabled check reaches ECS `HEALTHY`; an intentional failing check is detected.
- Services without the setting retain their existing task-definition and validation behavior, including services without ingress.

## Milestone 3 — Optional Private AWS Service Endpoints (Conditional)

**Work**
- Assess a tightly scoped, opt-in list of additional regional Interface VPC Endpoint services (e.g., `bedrock-runtime`).
- Reuse established endpoint-private subnets, security-group rules, private DNS, and ownership/validation patterns.
- Defer to a later release if safe implementation requires a broad networking or service-catalog refactor.

**Acceptance criteria**
- When included, a reference task reaches an explicitly enabled service privately, and endpoint inventory/configuration validation passes.
- Existing endpoints remain unchanged; no additional endpoints or charges are introduced when the option is unset.

## Milestone 4 — Integration Qualification and Documentation (Required)

**Work**
- Add focused positive/negative tests for new inputs, least privilege, and health behavior; include endpoint tests if Milestone 3 ships.
- Run a generic reference application through the existing publication → reviewed Apply → runtime validation → evidence workflow.
- Update usage examples, migration notes, and the ECS runtime contract without changing unrelated infrastructure.

**Acceptance criteria**
- Existing default configurations retain no-change Terraform plans; no unintended resource replacements or security regressions.
- New capabilities are demonstrated with live, retained evidence, including **16/16** workload validator success and GuardDuty Runtime Monitoring health where enabled.
- Release documentation clearly identifies tested functionality, skipped scenarios, and any deferred endpoint work.

## Deferred to v1.13.0 — Recovery Assurance and Edge Protection

- **Verified RDS recovery:** Exercise actual AWS Backup restoration with synthetic data checks, safe temporary-resource cleanup, and retained recovery evidence. Keep application-specific database validation outside the baseline.
- **AWS WAF:** Add opt-in managed-rule protection for public ALBs, with a safe monitoring/count-first rollout and live validation.
- **ALB access logs:** Add configurable, protected request-log delivery, retention, and validation appropriate to an ingress-enabled workload.

Broader Checkov remediation, cross-Region disaster recovery, generalized secret rotation, and advanced ECS patterns (multi-container, Service Connect, scheduled tasks) remain separate backlog items, not part of this release plan.
