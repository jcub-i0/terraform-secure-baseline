# Release Roadmap — v1.12.0 Application Runtime Extensibility

**Current release: v1.12.0.** The baseline provides application-agnostic SaaS
runtime extensions through the existing canonical `ecs_services` interface and
an environment-level private-endpoint input. All three capabilities are opt-in.
Terraform owns baseline infrastructure; application owners retain authorization
policy, health-command, and data-access decisions.

## Delivered scope and qualification dispositions

| Milestone | v1.12.0 implementation | Evidence and limits |
|---|---|---|
| M1 — Extensible ECS task IAM | Optional `task_role_managed_policy_arns`; application-role-only attachments, launch ordering, exact inventory validation; no default privilege expansion | 13 offline cases passed CI and live inventory checks were recorded during M2. The maintainer explicitly deferred the additional live allowed/denied API exercise; that original acceptance criterion is not PASS. |
| M2 — ECS-native container health | Optional `health_check`, task-definition parity, independent bounded live health polling; ALB and GuardDuty checks remain separate | 18 offline scenarios passed CI. Historical dev healthy-container and deliberately failing standalone-task observations are retained; managed-service rollback, ALB integration and multi-service scaling were not demonstrated by those tests. |
| M3 — Optional private AWS endpoints | `additional_interface_endpoint_services = []`; only `bedrock-runtime` approved; 16 mandatory endpoints preserved; exact ownership/inventory validation and Plan/Apply input wiring | 22 offline scenarios passed CI. Historical EC2 and temporary Fargate probes established private DNS/TLS/HTTP connectivity, not application IAM or inference. Enabled-state Apply and other archival provenance remain incomplete. |
| M4 — Integration and documentation | All three suites run in Static Analysis: 53 offline scenarios. Current release docs include usage, migration, security boundaries and qualification limits | CI run 39368786319 passed at `7002a421`. Consolidated application publication → reviewed Apply → runtime validation → evidence is not established by retained M4 evidence. Earlier M2/M3 tests are not new M4 executions. |

The [qualification record](docs/assurance/v1.12.0-qualification.md) is the detailed
ledger of acceptance evidence, operator reports, explicit exceptions, and unresolved
provenance. `16/16` denotes workload-validator results. It does not establish
complete application behavior, a fresh default/no-change plan, or SOC 2/ISO 27001
certification. Reviewer approval and release sign-off are not recorded by this
roadmap; finalized release terminology does not close those evidence gaps.

The [changelog](CHANGELOG.md) records changes since v1.11.1, and the
[quickstart](docs/quickstart.md#v1120-opt-in-configuration-and-upgrade) explains
opt-in migration. Existing service defaults, null-digest registration, execution
role separation, immutable image selection, and production/retirement boundaries
remain in place. Enabled optional endpoints add AWS charges.

## Deferred to v1.13.0 — Recovery Assurance and Edge Protection

- **Verified RDS recovery:** Exercise actual AWS Backup restoration with synthetic data checks, safe temporary-resource cleanup, and retained recovery evidence. Keep application-specific database validation outside the baseline.
- **AWS WAF:** Add opt-in managed-rule protection for public ALBs, with a safe monitoring/count-first rollout and live validation.
- **ALB access logs:** Add configurable, protected request-log delivery, retention, and validation appropriate to an ingress-enabled workload.

Broader Checkov remediation, cross-Region disaster recovery, generalized secret
rotation, and advanced ECS patterns (multi-container, Service Connect, scheduled
tasks) remain separate backlog items outside v1.12.0.
