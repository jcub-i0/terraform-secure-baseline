# v1.15.0 — M0-C: Reusable Module Interface Contracts

**Status:** **C1 architecture/design accepted** following local cross-repository re-review and PR #961 merge; publication and security controls remain unimplemented
**Starting point:** M0-B approved two-state architecture (PR #960, merge `2730b3b`)
**Scope:** C1 accepted design record; C2–C4 consolidated in [one follow-up design](./v1_15_0_M0_C2_C4_CONSOLIDATED_INTERFACE_DESIGN.md); C5/M0-D verification remains open
**Reference application:** ReconoSense (private checkout: `~/recon-engine/infra/terraform/`)

## Objective and boundaries

Define reusable interfaces that allow any sensitive-data SaaS application to consume foundation-owned AWS resources without co-owning them, inspecting the foundation Terraform state, or relaxing its security controls. The foundation remains the authoritative owner of VPC/RDS/KMS/ECS cluster/security governance. An adopter's separate application state owns its runtime and application resources.

**Owner-approved M0-B constraints:** D1/D2/B-3/B-5 remain in force. The first synthetic qualification uses the existing baseline staging account. The foundation owns RDS configuration and deletion; a separate, staging-only application run-state controller may be implemented later, subject to narrow IAM and safe lifecycle controls. Design approval does **not** authorize AWS access, deployments or state migration.

## M0-C work plan

| Checkpoint | Status | Deliverable and acceptance |
|---|---|---|
| **C1 — Foundation publication** | **Design accepted, not deployed** | Versioned non-secret infrastructure contract, exact publication identity, protected cross-state deployment coordination, ownership, schema/gap inventory and fail-closed consumer checks |
| **C2 — ECS and jobs** | **Consolidated design proposed** | Optional multi-container service, standalone task, Scheduler, per-task execution/task-role and launch-readiness interfaces; [C2–C4 package](./v1_15_0_M0_C2_C4_CONSOLIDATED_INTERFACE_DESIGN.md) |
| **C3 — Database and lifecycle** | **Consolidated design proposed** | Configurable new-instance PG16 (preserving existing 17.10 default), app credential separation, dedicated staging RDS `aws_rds_instance_state` interface and ordering/drain invariants |
| **C4 — Ingress and security integration** | **Consolidated design proposed** | ALB/ACM/DNS, per-rule SG connectivity ownership, app IAM boundaries, KMS/GuardDuty/WAF and private egress compatibility |
| **C5 — Verification and handoff** | Not started | Actual Terraform dependency-graph review, backward-compatible synthetic consumer, negative security tests specification, independent review and M0-D handoff |

**C1 is complete as an architecture-design checkpoint only** after the owner merged PR #961 (merge `127ecae`), following an independent local cross-repository review that returned **ACCEPT WITH DEFERRED ITEMS** and no blockers. C2–C4 are now designed together in the linked follow-up package; C5 and implementation/security acceptance remain open.

## C1 — Proposed foundation-to-application publication contract

### 1. Ownership and dependency direction

```text
Protected baseline bootstrap / existing account governance
                         |
                         v
Foundation Terraform state (existing workload account)
  VPC / subnets / endpoint SG / RDS / KMS / ECS cluster / ECR
                         |
           publishes reviewed, non-secret fields
                         v
Foundation-owned SSM Parameter (schema v1)
                         |
           app Plan: exact read-only parameter
                         v
Application Terraform state (new, separate backend/key)
  ECS services / task roles / ALB / jobs / data / identity
```

The foundation state **exclusively owns the SSM parameter resource** and its allowlisted payload; the application may only read it. A Terraform-managed parameter may be written *during* Foundation Apply. Its presence or a new SSM version is therefore **not proof of successful foundation deployment**. Only a separately protected, post-Apply validation and approval record may make the publication eligible for application deployment. Foundation Terraform never consumes application outputs; no independent CLI process may act as a competing writer to the Terraform-owned parameter.

**Proposed transport:** an SSM Parameter Store `String` containing a JSON object, e.g. `/tf-secure-baseline/staging/contracts/foundation/v1`. The prefix is illustrative and must be validated against the final naming/permissions model. It is not a Secrets Manager value and contains **no credentials**. This is a design preference, not a newly implemented SSM resource. The application role must not gain `terraform_remote_state` access, S3 access to `baseline/staging.tfstate`, or whole-bucket list/read permissions.

If a backend or identity design cannot guarantee state and publication isolation, fail the integration rather than make the application role a baseline Plan/Apply role.

### 2. Proposed v1 schema

The example is illustrative, contains placeholders, and is **not a deployed parameter**:

```json
{
  "schema_version": 1,
  "environment": "staging",
  "account_id": "<expected-12-digit-account-id>",
  "region": "us-east-1",
  "foundation_revision": "<approved-foundation-commit>",
  "network": {
    "vpc_id": "<vpc-id>",
    "compute_private_subnet_ids_by_az": {
      "us-east-1a": "<private-subnet-id-a>",
      "us-east-1b": "<private-subnet-id-b>"
    },
    "ingress_public_subnet_ids_by_az": {
      "us-east-1a": "<public-subnet-id-a>",
      "us-east-1b": "<public-subnet-id-b>"
    },
    "endpoint_security_group_id": "<endpoint-sg-id>",
    "s3_prefix_list_id": "<prefix-list-id>",
    "effective_egress_mode": "<approved-egress-mode>"
  },
  "database": {
    "identifier": "<rds-instance-identifier>",
    "arn": "<rds-instance-arn>",
    "address": "<database-hostname>",
    "port": 5432,
    "database_name": "<database-name>",
    "security_group_id": "<data-sg-id>",
    "engine": "postgres",
    "engine_version": "<observed-at-publication-engine-version>"
  },
  "ecs": {
    "cluster_name": "<ecs-cluster-name>",
    "cluster_arn": "<ecs-cluster-arn>",
    "guardduty_runtime_monitoring_expected": false,
    "guardduty_agent_ecr_repository_arn": null
  },
  "ecr_repositories": {
    "<stable-repository-key>": {
      "name": "<repository-name>",
      "arn": "<repository-arn>",
      "repository_url": "<registry-repository-url>",
      "owner": "foundation"
    }
  },
  "security": {
    "logs_kms_key_arn": "<logs-kms-arn>",
    "secrets_kms_key_arn": "<secrets-kms-arn>"
  },
  "capabilities": {
    "database_staging_run_state_eligible": false,
    "database_dedicated_to_application": false
  }
}
```

The two `capabilities.database_*` flags default to `false` and are **foundation-owned, informational eligibility declarations**, not authorization or evidence of the current RDS run state. Enabling either requires an independently approved dedicated-use review, an exactly identified application consumer and the published RDS ARN/account/Region. M0-C3/D must require both true and verify actual exclusive use before implementing any RDS run-state controller or IAM grants. The ordinary production baseline must not inherit staging-only lifecycle eligibility.

When `ecs.guardduty_runtime_monitoring_expected` is `true`, `ecs.guardduty_agent_ecr_repository_arn` must be an exact, non-null regional AWS-owned repository ARN published by the foundation; otherwise the application must fail closed rather than widen ECR permissions or reconstruct a regional account map. When monitoring is disabled, the ARN is `null`. The resolved ARN is **not** one of the application ECR repositories. M0-D must verify that task execution-role agent image pull grants are read-only and scoped to this exact ARN, with no wildcard repository substitution.

**Exact shape remains proposed, not ratified.** AZ-keyed subnet maps preserve the baseline's existing source topology; consumers must not infer stable ordering from a list. `capabilities` identifies reviewed eligibility or configuration, not an IAM grant, live connectivity test, or operational health signal. `foundation_revision` must be the full reviewed source commit (not a volatile `timestamp()`), but it does **not** uniquely identify a publication. Any changed contract or eligibility epoch requires a fresh approved application plan.

### 2A. Three identities and exact publication binding (C1-01)

These values are distinct; none substitutes for another:

| Identity | Meaning | Required consumer behavior |
|---|---|---|
| `schema_version` | Integer contract schema generation and field semantics | Accept only explicitly supported versions. Incompatible changes bump the schema version; additions and unknown fields require reviewed compatibility, never implicit permission. |
| `foundation_revision` | Full SHA of the reviewed source commit that produced the applied foundation configuration | Check against the independently approved commit. The same commit can produce different infrastructure values; this is **not** a publication identity. |
| **Publication identity** | Exact SSM parameter ARN/name, the AWS-returned **`Version`**, and `SHA-256` of the **exact UTF-8 `Value` bytes returned by `GetParameter`** | Capture all three together with the foundation revision, eligibility epoch and application plan digest in the protected plan manifest. Reject mismatches or missing historical versions; never accept a publication based only on schema/commit. |

The publication digest is **not a self-referential field in the JSON**. Hash the complete retrieved parameter `Value` bytes, not a locally re-serialized approximation; SSM's `Version` is AWS-generated and kept **outside** the JSON. The review manifest must preserve the parameter identity, version, hash, source revision, approved eligibility epoch and exact saved-plan artifact digest. Parameter values themselves remain non-secret. A separate immutable evidence archive may preserve reviewed historical payloads and digests for audit, **not** to authorize applying an old saved plan.

SSM Parameter Store retains only the most recent **100 versions**. A missing or pruned historical version fails closed and requires an up-to-date approval and new application Plan; the consumer may not silently fall back to a label, the current latest value, or an archived copy. Likewise, re-creating a deleted parameter cannot automatically reuse a former approval. The protected coordinator must invalidate its prior publication eligibility and approval epoch.

Target **Standard-tier `String`**, with a strict serialized UTF-8 size limit of **4,096 bytes**. If the allowlisted schema exceeds it, reject publication and seek a separately reviewed design (such as Advanced tier, whose limit is 8,192 bytes and which may incur charges); never truncate, silently change tiers or omit required fields. C2 must finalize the stable typed ECR entry inventory; repository `name`, `arn`, `repository_url` and `owner: foundation` are data, **not image-push grants**. C5 specifies size, version-history and serialization **test fixtures**; M0-D/M4/M5 implement and execute them after publication and release controls exist.

### 2B. Foundation publication and saved-plan safety protocol (C1-02)

**SSM parameter state alone is insufficient to authorize deployment.** A protected release coordinator must own an independent, durable **deployment eligibility / exclusive coordination record** per target environment. Its administration belongs to the existing protected foundation/bootstrap authority—not the application state, not a third workload Terraform state and not the application's ordinary Plan role. This proposed coordination record is **not implemented**. M0-D must choose the actual AWS-enforced lease/status mechanism, its single authoritative controller, IAM/trust, stale-lock recovery and cross-repository invocation; repository-local GitHub Actions concurrency alone cannot be assumed to serialize two repositories.

The required protocol is:

1. **Block foundation changes before they begin:** acquire the environment-wide exclusive lease and durably set eligibility to `BLOCKED` before any potentially mutating foundation Apply or retirement operation. Prevent new application Apply operations during this window. A failed, interrupted, cancelled or partially successful foundation change leaves the gate `BLOCKED` until protected reconciliation—not automatically eligible because SSM still returns the previous value.
2. **Apply under foundation ownership:** the existing foundation Terraform state owns and may write the SSM parameter *during* its saved-plan Apply, as a normal managed resource. Do not claim that Terraform waits for the entire Apply to succeed before updating this particular resource, and do not add a second writer after Apply. On failure, do not trust either the old or new SSM value.
3. **Qualify and activate:** only after the whole foundation Apply **succeeds** and required AWS-side/resource, identity, interface and security validations pass may the protected coordinator read `GetParameter`, verify its exact `Version`/`Value` digest and source revision, then persist the approved publication identity and advance a monotonic eligibility epoch. Release the lease only after that approved record is durable.
4. **Plan against one approval:** application Plan requires `ELIGIBLE` and reads the approved exact parameter through its own narrow SSM read permissions. It validates the schema, account/Region/environment, necessary capabilities, current approval epoch and the complete publication identity. Store the exact identity, epoch, reviewed application source revision and Terraform saved-plan checksum together in a protected plan manifest. This does **not** imply that a data source will re-read SSM at Apply.
5. **Recheck immediately before Apply:** the protected application release coordinator obtains the **same environment-wide exclusive lease**, checks that the foundation gate is `ELIGIBLE`, independently re-reads the *current* SSM parameter and verifies its exact version/digest plus foundation commit and eligibility epoch against the approved saved-plan manifest. Any mismatch, missing publication, stale approval, expired history or concurrent foundation operation aborts Apply and requires a fresh Plan/review. **Hold the lease through saved-plan Apply and application acceptance checks**; foundation changes cannot run concurrently. Capture the result for evidence before releasing the lease.
6. **Recovery and retirement:** a coordinator failure or unclear operation outcome blocks new applies pending protected operator reconciliation. Foundation retirement requires verified application drain/teardown first and is mutually excluded by the same coordination control. Out-of-band AWS drift or role/policy bypass can defeat the protocol; M0-D must restrict mutation paths and require drift/security monitoring rather than claiming the SSM payload proves live state.

**Race/failure acceptance:** C5 defines the test cases, and M0-D/M4/M5 must execute them after implementation: an interrupted foundation Apply before publication, a failed Apply after SSM update, an application Plan made under publication A followed by foundation publication B, a foundation change arriving during application Apply, a missing/pruned SSM version, stale/malformed documents and concurrent-release attempts. Every unsafe path must fail closed. A controller must not implement arbitrary external `PutParameter` writes to the Terraform-managed contract.

### 3. Source and gap inventory

| Proposed field | Existing source | Gap / owner |
|---|---|---|
| Account, Region, environment, revision | Environment/root inputs, `aws_caller_identity`, `data.aws_region` and release CI | **Foundation:** publish verified identity/revision without exposing state |
| VPC, private/public subnets | `baseline/outputs.tf`: `vpc_id`, `network_topology.compute_private_subnet_ids_by_az`, `network_topology.ingress_public_subnet_ids_by_az` | **Foundation:** publish the existing AZ-keyed maps; consumers derive lists or sets without assuming AZ ordering |
| Endpoint SG and S3 prefix list | `modules/vpc_endpoints/outputs.tf`: `interface_endpoints_sg_id`; root `s3_prefix_list_id` | **Foundation:** expose endpoint SG only in reviewed non-secret contract |
| RDS ID/ARN/endpoint/port/name/SG | `modules/storage/outputs.tf` `rds_configuration.identifier/arn`; root `rds_address`, `rds_port`, `rds_database_name`, `data_sg_id` | **Foundation:** purpose-built fields, not broad `rds_configuration` publication |
| RDS engine and lifecycle eligibility | Storage instance currently hardcodes `17.10`; AWS provider resource attribute `aws_db_instance.main.engine_version_actual` represents observed engine version at refresh/publication (not continuous observation). No dedicated-use/run-state approval input exists. | **C3:** publish engine `postgres` and observed-at-publication minor version; revalidate after upgrades, qualify new PG16 and protected staging eligibility; never downgrade PG17 in place |
| ECS cluster and monitoring | Root `ecs_cluster` output includes ARN/name and GuardDuty expected participation; `baseline/locals.tf` resolves `local.guardduty_fargate_agent_ecr_repository_arn` by supported Region, but the root does **not** publish that value when there is no deployable foundation service | **Foundation:** add an explicit resolved `guardduty_agent_ecr_repository_arn` contract field independent of `ecs_services`; require it when monitoring is enabled. **M0-D:** test exact agent-repository pull-only grants and reject missing/wildcard scopes |
| ECR repository inventory | Root `ecr_repositories` provides name/ARN/URL and additional fields; null-digest service registration may still derive a repository | **Foundation/C2:** explicitly pin repository inventory/ownership and serialize only typed name/ARN/URL/owner entries; avoid unintended ECR deletion and do not confuse publishing with permission to push |
| Logs and secrets CMK ARNs | Root `logs_cmk_arn`, `secrets_manager_cmk_arn` | **Foundation publishes references only; M0-D** enforces actual use permissions and KMS key policy |
| Mandatory role permissions boundary | Platform/bootstrap-governed, not currently a `baseline/outputs.tf` field | **M0-D:** publish/validate a platform-administered ceiling separately or via protected input; do not fabricate an ARN or let app CI control the boundary |
| ALB canonical hosted zone ID | App-owned ALB module currently exposes DNS name but not canonical hosted zone ID | **C4:** add generic ALB output or authorized lookup; **not** a foundation field because app owns its ALB |
| SG connectivity grants | Existing `modules/networking/security_policy` creates mandatory foundation rules | **C4/M0-D:** application-only rule interface or protected platform-owned grant; never call the entire foundation module from app state |

The schema must not include the foundation RDS master username/password/secret ARN, secret versions or values, full state contents, application tenant details, document identifiers, customer data, or deployer credentials. No fields may be added simply because a preexisting root output happens to expose them.

### 4. Producer and consumer controls

**Foundation producer (future implementation):**

- Materializes the exact SSM contract parameter from allowlisted foundation attributes via protected foundation Terraform Apply only; no application-dependent references, competing writers, or back edges.
- Separately owns IAM for that resource. The protected coordinator blocks deployment eligibility before foundation changes and approves the resulting publication **only after successful full Apply and post-Apply validation** (section 2B); parameter existence/version never constitutes approval.
- Has deterministic serialization, payload-size and schema-validation tests; no secret-bearing output can enter the document. A foundation destroy/retirement cannot proceed with an active application dependency or unreconciled deployment gate.

**Application reader (future implementation):**

- Reads only the exact parameter by name through its Plan role, with no SSM mutation, recursive path read, foundation state-object access or foundation IAM authority. Checks the independent protected eligibility record; published SSM data alone cannot authorize an Apply.
- Rejects missing/unsupported schema, wrong account/Region/environment, malformed IDs, unapproved lifecycle eligibility, unqualified capabilities or changed publication identity. A static contract does not report real-time DB availability, active network reachability or IAM permission.
- Binds the complete SSM name/ARN/version/digest, source revision, eligibility epoch and saved-plan checksum to the reviewed plan. Immediately before protected Apply, re-read/revalidate all of them **under the shared environment lock held until Apply/acceptance finishes** (section 2B). Any mismatch requires a new Plan.
- Keeps Plan/Apply identities separate and fails closed when publication or gate validation fails.
- Does not automatically acquire KMS decryption, RDS configuration, foundation SG mutation, or Bedrock permissions merely by receiving ARNs.

**Security acceptance is deferred to M0-D:** IAM trust, S3 state-object and lockfile isolation, KMS restrictions, SG-grant authorization and exact-ARN RDS Start/Stop rights must be independently proven through positive and negative tests. This PR does not grant any such permissions.

### 5. C1 design acceptance and deferred implementation criteria

- [x] C1 schema, versioning, publication identity and approved field classes accepted **as a design** when PR #961 was merged.
- [x] Protocol defines SSM ARN/name + exact AWS version + SHA-256 of retrieved value, source revision, epoch and protected saved-plan manifest; unsafe history/recreation cases fail closed **by design**.
- [x] Coordinator design covers partial foundation Apply, blocked eligibility, post-Apply approval and cross-repository exclusive release admission without a second SSM writer or third Terraform workload state.
- [x] All 17 ReconoSense integration contracts were cross-referenced by local Codex; original C1-01/C1-02 blockers were resolved with a final **ACCEPT WITH DEFERRED ITEMS** recommendation. Owner merged PR #961.
- [ ] **Implementation outstanding:** actual SSM publication, independent coordinator, permissions boundaries, KMS/IAM, state isolation and fail-closed controls (M0-D and implementation milestones).
- [ ] **Verification outstanding:** C5 documents exact identity/version/history/UTF-8 size, concurrency and graph/compatibility test fixtures; executable tests and backward-compatible deployments are required in M0-D/M1–M5 after implementation.
- [ ] **Later interfaces outstanding:** C2–C4 application/runtime interfaces require consolidated design acceptance and implementation through M1–M4.

## Handoff to C2–C5 and M0-D

**C2:** Design optional `containers` / `ecs_tasks` / `schedules` interfaces, per-container dependencies and distinct task/execution IAM. Finalize foundation-owned typed ECR repository entries and explicit repository registration (null image digest alone must not control repository lifecycle). Preserve current single-container defaults and resource addresses.

**C3:** Preserve the baseline's PostgreSQL 17.10 default and qualify PostgreSQL 16 for **new** instances; source the published observed engine version from `aws_db_instance.main.engine_version_actual` and revalidate after minor upgrades. Specify distinct application secrets and the owner-approved staging-only run-state controller. Require exclusive-use proof, stop/drain coordination, start-before-migrate, autoscaling controls and safe teardown (destroying the controller does not restart RDS; AWS may restart stopped RDS after seven days).

**C4:** Specify application-owned ALB/ACM/DNS resources and private ECS security rules without duplicating foundation security-policy rules. Define a non-authoritative network capabilities/qualification interface (available VPC endpoint services, private DNS behavior, and approved HTTPS destinations); `effective_egress_mode` alone is not evidence that Cognito JWKS/Bedrock or image updates are reachable. Preserve WAF/ALB logging/deletion safeguards, GuardDuty execution-role pulls, CMK-compatible secrets and 50 MiB upload handling.

**C5:** Review the **existing-source dependency relationships** and specify representative future graph, version/history/UTF-8 size/serialization, publication identity, saved-plan and cross-repository race/failure negative-test fixtures, including unchanged resource ownership and default addresses. **M0-D/M1–M5 must execute the actual graph, Plan and failure tests against implemented code.** An architecture diagram is not a successful graph test.

**M0-D:** Implement and negatively test the protected cross-repository eligibility/lease mechanism, app Plan/Apply/release scope, mandatory independently controlled permission boundaries, RDS Start/Stop, SG grants and KMS/S3 isolation. Ensure generic execution-role secret CMK decrypt and GuardDuty image-pull requirements are not bypassed. The owner-approved two-state design is not implementation permission.

## Independent cross-repository Codex review dispositions

The initial local read-only review at `183eae1` of private ReconoSense reported **C1-01/C1-02 BLOCKING** and **C1-03–C1-07 NONBLOCKING**. The subsequent local cross-repository re-review of `c651cbba` resolved both blockers as architecture requirements, added nonblocking C1-R1 (coordinate *complete* releases/lifecycle paths) and returned **ACCEPT WITH DEFERRED ITEMS**; the owner merged PR #961. The decisions are accepted as design **only**: no SSM/IAM/lease implementation or live qualification exists.

| Finding | Revised disposition | Remaining verification |
|---|---|---|
| **C1-01 — BLOCKING** | Specify schema vs source vs SSM version + raw-value digest and binding to approved release epoch/plan | C5/M0-D: replacement/rotation, history expiry, hash mismatch, stale plan |
| **C1-02 — BLOCKING** | Separate Terraform-owned SSM publication from post-success eligibility; serialize cross-repository foundation/apply operations and pre-Apply revalidation | C5/M0-D: failed/partial Apply, publication A→B, lease races, cancellation/retirement |
| **C1-03 — NONBLOCKING** | Typed, foundation-owned ECR entry illustrated; 4 KiB/8 KiB limit and explicit failure policy documented | C2 inventory ownership; C5 UTF-8 size/version-history tests |
| **C1-04 — NONBLOCKING** | Egress mode explicitly not a connectivity guarantee | C4 endpoint/HTTPS qualification; M0-D network enforcement |
| **C1-05 — NONBLOCKING** | Direct module reuse does not imply mandatory IAM boundaries or CMK rights | C2–C4 interfaces; M0-D security/negative IAM tests |
| **C1-06 — NONBLOCKING** | WAF managed body-size rule requires scoped treatment for 50 MiB uploads, not blanket counting/disablement | C4 upload-specific policy; M5 positive/negative live tests |
| **C1-07 — NONBLOCKING** | Engine version now explicitly observed at publication from provider's `engine_version_actual` | C3 PG16 compatibility and upgrade revalidation |

No live Terraform graph, AWS Plan/Apply, SSM publication, IAM grant, security qualification, or accepted C1 is claimed.

## Review instructions and source references

This initial C1 document should be reviewed against the exact branch diff and, when the reviewer has access, the private ReconoSense `infra/terraform/BASELINE_INTEGRATION.md` at `~/recon-engine/`. No private repository hyperlinks are included because public Docs Validation cannot authenticate to them.

Public baseline source:

- [M0-B architecture acceptance](./v1_15_0_M0_B_ARCHITECTURE_AND_TF_OWNERSHIP.md)
- [M0 architecture inventory](./v1_15_0_M0_ARCHITECTURE_OWNERSHIP.md)
- [Baseline outputs](../baseline/outputs.tf)
- [Storage outputs](../modules/storage/outputs.tf)
- [VPC endpoints outputs](../modules/vpc_endpoints/outputs.tf)
- [ECS cluster outputs](../modules/ecs_cluster/outputs.tf)
- [ALB outputs](../modules/application_load_balancer/outputs.tf)

**C1 acceptance is design-only. No Terraform changes, AWS deployment, published SSM parameter, live contract or security qualification is claimed by the C1 and consolidated C2–C4 documentation PRs.**
