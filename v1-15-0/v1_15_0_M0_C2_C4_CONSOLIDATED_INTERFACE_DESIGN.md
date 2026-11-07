# v1.15.0 — M0-C2–C4: Consolidated Reusable Interface Design

**Status:** Proposed for consolidated owner review; documentation only
**Baseline:** `main` after PR #961 (merge `127ecae`); M0-A/B complete, C1 design accepted
**Scope:** C2 ECS and background work, C3 database/lifecycle, C4 ingress/security integration
**Reference application:** ReconoSense (private contract at `infra/terraform/BASELINE_INTEGRATION.md`)

## 1. Objective and fixed boundaries

Define the remaining reusable module **interfaces** in one design work package, not three separate approval cycles. ReconoSense exercises the requirements, but jobs, tenant policy, SQL, model access, identity configuration and release commands remain in the adopter's repository. This document makes **proposals**, not Terraform or AWS changes.

The approved [M0-B ownership model](./v1_15_0_M0_B_ARCHITECTURE_AND_TF_OWNERSHIP.md) is fixed: the existing baseline staging root owns VPC, endpoints, RDS configuration/deletion, KMS, ECS cluster, security governance and approved ECR repositories; the separate application state owns application services, tasks, ALB, IAM subject to platform controls, identity and data resources. The foundation consumes **no application-state outputs**. Reuse version-pinned baseline modules without duplicating their AWS resource instances. The accepted [C1 publication contract](./v1_15_0_M0_C_REUSABLE_MODULE_INTERFACES.md) is a non-secret SSM interface plus a separately protected publication eligibility/coordination protocol; it has **not been implemented**.

**Scope discipline:** C2–C4 are designed together here. C5 remains one integrated graph/default-compatibility review, and M0-D/E/F should be handled as one final security/economics/licensing/acceptance package. Executable positive/negative tests belong to M1–M5 and the security implementation gates, not to repeated M0 paperwork.

## 2. Existing modules and non-regression contract

| Source | Verified current behavior | Proposed extension boundary |
|---|---|---|
| `modules/ecs_service/variables.tf` and `main.tf` | `services` is a map with a single required digest-pinned `image`, required port, task/execution-role ARNs, CPU/memory and optional scaling; the task definition serializes one essential container. The service and task definition use the existing keyed resource addresses. | Add opt-in sidecar/container composition; preserve the legacy one-container serialization and keys when not configured. |
| `modules/ecs_service/main.tf` | Fixed-count `aws_ecs_service.services` and autoscaled `aws_ecs_service.autoscaled_services` are separate. Autoscaled services ignore Terraform `desired_count` changes. Fargate tasks run in compute-private subnets with `assign_public_ip = false`. | Do not move existing service addresses or treat `desired_count = 0` as a valid parking control for autoscaled services. |
| `modules/iam/ecs.tf` | Per-service task and execution roles, ECR pull, GuardDuty agent pull, log write, Secrets Manager read, SSM read and optional execution KMS decrypt; ECS roles currently lack a mandatory permissions boundary. | Expose generic boundaries and per-job policies without reusing platform-wide IAM roles or inadvertently broadening execution roles. |
| `modules/networking/security_policy/main.tf` | Unconditionally creates foundation compute/automation/endpoint rules plus optional ECS rules, including mutations of DB/endpoint SGs. | Do **not** call the full platform security-policy module from the application state. Define opt-in application-facing network interfaces with one owner per rule. |
| `modules/application_load_balancer` | Owns HTTPS ALB, target groups, listener routes, access-log bucket and optional WAF. Default target-group health matcher is `200-399`; no canonical ALB hosted-zone output. WAF enforces managed Common/KnownBadInputs groups without individual size-rule overrides. | Preserve defaults; optionally support exact matcher, hosted-zone output and narrowly scoped large-body handling while retaining the other protections. |
| `modules/storage/main.tf` | Foundation owns `aws_db_instance.main` PostgreSQL `17.10`, RDS SG, master secret, logs and backup integrations. | Add configurable engine version defaulting to `17.10` and publish **observed-at-publication** version; never import/duplicate application RDS or force an in-place downgrade. |
| `baseline/locals.tf` | ECR repositories are derived from both explicit `repositories` and service registrations, even when an image digest is null. | Make integration repository inventory explicit and stable across service registration or image changes. |

The existing `baseline/` root, resource addresses, output names, opt-in defaults and single-container consumer behavior must not change merely because the new application calls lower-level modules.

## 3. C2 — ECS services, standalone jobs and schedules

### 3.1 Additive ECS service interface

**Preferred design:** retain the existing `services` map and its primary-container fields (including required digest-pinned `image`, `container_port` and roles) for existing users. Add an optional, default-empty `sidecars` map and optional task-scoped volume/mount/ephemeral-storage configuration. A fully generic `containers` map may be evaluated for new integrations only if its default normalization produces **the exact legacy container** without moving resource addresses.

| New optional field group | Interface contract |
|---|---|
| `sidecars` map, keyed by stable container name | Digest-pinned image, `essential` default, optional command/entrypoint, environment and Secrets Manager/SSM references, health check, port mappings, per-container CPU/memory reservations, logging metadata and optional read-only root filesystem. No app-specific names or default images. |
| `depends_on` per container | List of existing sibling container names and ECS conditions (`START`, `COMPLETE`, `SUCCESS`, `HEALTHY` where valid). Reject missing dependencies, self/cyclic dependencies, or `HEALTHY` when the prerequisite lacks a health check. Ensure a container required to stay active is not accidentally nonessential. |
| `task_volumes` and container `mount_points` | Optional task-local shared volume references, validated mount names and read-only flags; needed for generic in-task socket/scratch exchange but not tailored to any antivirus implementation. |
| `ephemeral_storage_gib` | Optional supported Fargate ephemeral-storage size with AWS/provider bounds; default remains existing behavior. |
| `primary_container` selection | Default remains the service key. ALB target group must name/port the actual selected essential serving container. A nondefault name is an explicit opt-in and cannot silently rename existing containers. |
| `execution_policy_ids`, `task_role_policy_attachment_ids`, `security_policy_rule_ids` | Retain existing launch-readiness dependency handoffs and extend to new roles, secrets, KMS, network grants and task policies; do not replace them with broad module-level `depends_on` cycles. |

**Invariant:** For omitted new inputs, `container_definitions` retains the existing one-essential-container format, name, log group and target port, and the current `aws_ecs_task_definition.task_definitions[service]` and fixed/autoscaled service addresses remain unchanged. With opt-in sidecars, deterministic container ordering avoids perpetual task-definition diffs. Digest-only image references apply to every image, including sidecars.

### 3.2 Generic standalone task-definition and invocation interface

Introduce an **opt-in** standalone Fargate task-definition module (new code in M2), separate from `aws_ecs_service`. A task definition does **not** create an ECS service, a second ECS cluster or a permanently running job.

| Input/output | Proposed behavior |
|---|---|
| `tasks` keyed map | Stable task-family key, digest-pinned containers, CPU/memory/architecture, optional scratch volumes, secrets, environment, logging, retries/timeouts declared by application orchestration and distinct task/execution-role ARNs. |
| `cluster_arn` / private network | Consume C1's foundation cluster and private subnets; no task-side public IP. Allow only explicitly approved security-group attachments. |
| Launch dependencies | Export task-definition ARN and revision, log group metadata, policy attachment readiness and network grant prerequisites before any scheduler or protected release starts jobs. |
| On-demand invocation | The application release system owns `RunTask` and exact task-definition revision, cluster, network, role and bounded count. Only authorized jobs/models may run; no generic wildcard Bedrock access. |
| Failure observability | App-owned EventBridge task-state filters must scope by cluster **and** selected task-definition family/identity; distinguish startup failures, stopped tasks and nonzero container exit, avoiding alerts on unrelated apps in the shared cluster. |

ReconoSense's seven jobs are a **test case**, not seven names hardcoded into the baseline. A generic example must include at least two independently authorized jobs with distinct roles. An application migration task is treated as a job whose **successful exit** is a release gate, not an always-on ECS service.

### 3.3 Optional EventBridge Scheduler interface

Propose a separate `schedules` keyed map of **disabled-by-default** scheduler definitions referencing explicitly approved task-definition revisions and cluster/network bindings. Each schedule controls expression, timezone, target job key, optional retry policy, KMS encryption and its own DLQ/alert integration. Application state owns schedules, schedule execution roles, destination queues, alarm subscriptions and log filters; platform SecOps topics are not duplicated.

Scheduler trust must be bounded to permitted task revisions and `iam:PassRole` targets. An extraction job or similarly sensitive task remains disabled until application-authorized activation; schedule existence is not permission to access tenant data. Disable schedules and drain active jobs before lifecycle parking or application teardown.

### 3.4 ECR and release boundary

Foundation **explicitly inventories** repositories needed by the application; repository existence must not disappear when a service is removed or its image is null. C1 publishes typed name/ARN/URL/`owner = foundation` metadata without image-push authority. Application image CI receives separately scoped push rights and records digest and provenance. Reuse existing baseline's image-release workflow **only for foundation-owned services**, never as a second writer for application-owned ECS services.

Keep the C1 protected coordination lease across the **full application release**—worker/task publication, bounded migration, application-state API promotion and release acceptance—not merely a single Terraform command. Any failed migration prevents serving API promotion. The authoritative application Terraform state must reflect the promoted task definition; do not introduce drift through unmanaged `aws ecs update-service` calls. Implementation and negative tests belong to M4/M0-D.

## 4. C3 — RDS version, credentials and staging lifecycle

| Contract | Proposed design | Owning implementation/qualification |
|---|---|---|
| RDS engine | Add optional `rds_engine_version` with default `17.10` to `modules/storage` and thread through baseline root. Explicit PostgreSQL 16 is allowed **only for new, separately approved instances**; existing 17.x is never silently downgraded. | M3: input validation, clean PG16 plan/Apply, unchanged default plan and rollback/upgrade policy. |
| Observed version | Foundation C1 contract gets `engine = postgres` and `engine_version` from `aws_db_instance.main.engine_version_actual` **at publication**. It is not a live status probe or continuously fresh patch-level check. | M3/C5: source verification and post-upgrade re-publication/drift qualification. |
| DB credential roles | Foundation owns master secret and initial privileged provisioning. Application owns distinct DB-owner and runtime credentials, their app secrets and SQL grants, with no master secret ARN/value included in C1. | M3/M0-D: controlled first-install bootstrap, write-only/ephemeral secret handling, exact KMS decrypt and denied master access. |
| Delegated run state (B-5) | One application-state `aws_rds_instance_state` controller may manage **only the approved, exclusively assigned synthetic staging DB** identified by C1's exact ARN/identifier/account/Region. Foundation retains `aws_db_instance`/configuration, backup, deletion and master secret. | M3/M0-D: exact ARN-based Start/Stop, dedicated-use approval, read-only status checks, deny Modify/Delete/other DBs. |
| State transitions | `running`, `maintenance`, `parked` are **application lifecycle intents**, not foundation Terraform values. Resume DB and wait for availability **before** migrations/API; disable schedules, scale/drain services and jobs **before** parking. | M3/M4: migration barrier, autoscaled-service scale-to-zero guard, idle-job checks, bounded concurrency and error recovery. |
| Teardown | Destroying the run-state controller does not automatically restart or delete foundation RDS. RDS may restart stopped instances after seven days. Foundation retirement requires separate approved teardown order. | M3/M5: no accidental DB deletion, no assumed perpetual parking, operator recovery and retained evidence. |

**Cross-state invariant:** No app Terraform mutation of `aws_db_instance` and no foundation `aws_rds_instance_state`. The protected C1 release coordinator also serializes foundation maintenance against full application transitions, including migrations and rollback. This staging-only delegation does not apply automatically to production or multi-consumer databases.

## 5. C4 — ALB, SG rule ownership, egress and protective controls

### 5.1 Application ingress

Application state alone owns its HTTPS ALB, ALB SG, target groups, listener/routes, WAF/association, optional access-log bucket/policy and application hostname/ACM/DNS references. An existing external DNS hosted zone remains owned by its existing account/administrator; the application may own only authorized records.

The reusable ALB module should export the ALB's **canonical hosted-zone ID** alongside DNS name. A configurable `health_check_matcher` may allow exact `200`, while default `200-399` and all legacy resource addresses remain unchanged. Application callback hostnames/routes and application-specific response paths are not baseline defaults.

For approved upload routes, WAF must preserve managed groups, rate limits and other inspections while applying a **route/method-scoped, narrow handling** of `SizeRestrictions_BODY`. Do not disable the entire Common Rule Set, blanket-allow upload traffic or claim AWS WAF sees all 50 MiB; enforce request size, content validation, authorization and malware scanning downstream. M5 verifies allowed 50 MiB uploads and denied malicious/oversized payloads.

### 5.2 Connectivity without reverse Terraform ownership

The application owns task SGs and app ALB/task ingress/egress rules, but must not invoke `modules/networking/security_policy` from its state: that module unconditionally owns platform rules.

**Preferred candidate for M0-D security approval:** foundation pre-creates narrowly scoped **connectivity-grant security groups and foundation-owned ingress rules** for database/endpoint access, with published grant IDs. Application tasks may attach only the approved grant SGs under independently enforced identity/resource admission controls; no foundation rule may reference an application-created SG or require a foundation Apply whenever application SGs change. Foundation-owned grant SGs must not expose broad default egress, and application CI must not create, change, or delete their rules. If task SG-attachment authorization cannot be securely bounded, this candidate is **not approved**; choose another explicitly reviewed two-state mechanism rather than silently widening foundation SG access or introducing a third state.

Generic ECS service/task interfaces may accept a list of reviewed `additional_task_security_group_ids` without modifying their existing default singleton SG behavior. Existing platform task traffic remains on compute-private subnets and `assign_public_ip = false`.

### 5.3 Network and security qualification

The C1 `effective_egress_mode` describes configuration, **not observed reachability**. Extend the generic qualification contract with the available interface endpoint services, private-DNS behavior and independently approved permitted HTTPS destination categories. Application-specific hostnames, Cognito/JWKS URLs and Bedrock model/Region choices remain in the adopter root. Never turn on unrestricted outbound rules simply because a required service fails. M3/M5 must test actual private-subnet paths for AWS auth, image pulls, service-to-service calls, updates and extraction.

IAM boundaries remain under independently controlled bootstrap authority. Application task/execution roles must enforce mandatory boundaries and per-role PassRole/trust scopes; the current platform-wide `modules/iam` is **not** an application-only module. Execution-role KMS decrypt permission must be compatible with the actual application-secret CMK. GuardDuty agent ECR image pulls require the exact regional ARN from C1, with separately handled ECR authorization tokens and runtime-monitoring coverage checks.

Preserve ALB access logging, TLS policy, delete protection, app log encryption, alerts, secret separation and data/evidence-retention protections. An ARN supplied by C1 is **not** a grant of IAM/KMS/resource-policy access.

## 6. Integrated dependency and ownership order

1. Protected platform/bootstrap establishes account governance, permission ceilings and application state/lease authorities.
2. Foundation protected Plan/Apply provisions and validates shared VPC/endpoints/RDS/KMS/ECS/ECR and preapproved connectivity grants.
3. Foundation-managed SSM publication plus separate protected C1 coordinator attest exact successful publication (name, version, digest, revision, epoch); no application can read foundation Terraform state.
4. Application protected Plan consumes that publication and builds app-owned ALB, IAM, task definitions/jobs/schedules/SGs and app-data resources through **version-pinned** generic baseline modules.
5. Application protected Apply verifies the same current publication and approval epoch under the cross-repository environment lease; applies app resources without duplicating foundation resources.
6. Application release within the protected lease makes jobs available, executes migration to zero exit and only then promotes the app-owned ECS service through its authoritative Terraform state. Unsafe partial/failed releases stay blocked for reconciliation.
7. App teardown disables schedules, drains jobs/services, handles run-state controller and app-owned data under retention policy. Foundation retirement occurs separately, after approved dependency cleanup.

Do not use unconditional module-level dependencies that introduce ALB ↔ SG ↔ ECS cycles. In C5 verify **actual** Terraform graphs for representative empty, legacy single-container, and new multi-container/job compositions.

## 7. Consolidated design decisions and acceptance

| Decision | Proposed default | Status |
|---|---|---|
| **C2-D1** | Additive sidecars and optional task storage to existing `ecs_service`; preserve single-container input defaults and service/task addresses. | Proposed |
| **C2-D2** | New optional standalone-task and Scheduler modules; per-job task/execution roles, bounded RunTask, disabled schedules. | Proposed |
| **C2-D3** | Explicit foundation ECR repository inventory independent of image/deployable-service registration; application owns digest publication only. | Proposed |
| **C3-D1** | Configurable **new-instance** PostgreSQL 16 with baseline `17.10` default; observed-version publication and separate app credentials. | Proposed |
| **C3-D2** | Implement previously owner-approved **B-5** lifecycle split only for designated synthetic staging; hold full-release coordination. | Implementation/security gates open |
| **C4-D1** | Application-owned ALB/ACM/DNS records, canonical ALB zone output and opt-in exact-200 health match. | Proposed |
| **C4-D2** | Evaluate platform-created connectivity-grant SGs plus independently bounded app attachment as first no-reverse-dependency mechanism. | Candidate; requires M0-D proof/approval |
| **C4-D3** | Narrow per-rule upload WAF treatment, application egress qualification, mandatory IAM/CMK/GuardDuty safeguards. | Proposed |

**Consolidated acceptance checklist (design only):**

- [ ] Owner accepts or amends the above C2–C4 reusable interface choices **as one package**.
- [ ] An independent source-based review finds no unresolved *architecture-level* blocker across all 17 ReconoSense contracts; preserve nonblocking implementation/security requirements.
- [ ] Current single-container defaults, resource ownership, initial-account separation and C1 protected coordination remain explicit.
- [ ] C5 owns one focused dependency/compatibility plan; M0-D/E/F own the **single combined final security, cost, licensing and architecture closeout**.
- [ ] Docs CI/Static Analysis pass at the final PR head; no Terraform Plan/Apply/AWS test is represented as completed.

**Release work remains:** M1 implements multi-container services; M2 implements jobs/schedules; M3 implements data/network/security interfaces; M4 implements migration-aware promotion; M5 live-qualifies ReconoSense with synthetic data. This document authorizes none of those operations.

## References

- [M0 architecture and contract inventory](./v1_15_0_M0_ARCHITECTURE_OWNERSHIP.md)
- [M0-B accepted Terraform ownership design](./v1_15_0_M0_B_ARCHITECTURE_AND_TF_OWNERSHIP.md)
- [M0-C1 accepted publication design](./v1_15_0_M0_C_REUSABLE_MODULE_INTERFACES.md)
- [ECS service variables](../modules/ecs_service/variables.tf)
- [ECS service implementation](../modules/ecs_service/main.tf)
- [ECS IAM roles and policies](../modules/iam/ecs.tf)
- [Networking security rules](../modules/networking/security_policy/main.tf)
- [Application ALB module](../modules/application_load_balancer/main.tf)
- [WAF implementation](../modules/application_load_balancer/waf.tf)
- [RDS foundation instance](../modules/storage/main.tf)

**No Terraform code, AWS policies, state files, contracts, deployment workflows or infrastructure were modified by this design PR.**
