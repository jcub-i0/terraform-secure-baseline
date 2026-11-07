# v1.15.0 — M0-C: Reusable Module Interface Contracts

**Status:** In progress — C1 proposal for review; not yet accepted
**Starting point:** M0-B approved two-state architecture (PR #960, merge `2730b3b`)
**Scope of this PR:** Documentation only; define C1 and track C2–C5 design gates
**Reference application:** ReconoSense (private checkout: `~/recon-engine/infra/terraform/`)

## Objective and boundaries

Define reusable interfaces that allow any sensitive-data SaaS application to consume foundation-owned AWS resources without co-owning them, inspecting the foundation Terraform state, or relaxing its security controls. The foundation remains the authoritative owner of VPC/RDS/KMS/ECS cluster/security governance. An adopter's separate application state owns its runtime and application resources.

**Owner-approved M0-B constraints:** D1/D2/B-3/B-5 remain in force. The first synthetic qualification uses the existing baseline staging account. The foundation owns RDS configuration and deletion; a separate, staging-only application run-state controller may be implemented later, subject to narrow IAM and safe lifecycle controls. Design approval does **not** authorize AWS access, deployments or state migration.

## M0-C work plan

| Checkpoint | Status | Deliverable and acceptance |
|---|---|---|
| **C1 — Foundation publication** | **Proposed in this PR** | Versioned, explicitly published **non-secret** infrastructure contract; ownership, schema, source/output gap inventory, fail-closed consumer checks |
| **C2 — ECS and jobs** | Not started | Optional multi-container service, standalone task, Scheduler, per-task execution/task-role and launch-readiness interfaces; synthetic single-container regression |
| **C3 — Database and lifecycle** | Not started | Configurable new-instance PG16 (preserving existing 17.10 default), app credential separation, dedicated staging RDS `aws_rds_instance_state` interface and ordering/drain invariants |
| **C4 — Ingress and security integration** | Not started | ALB/ACM/DNS, per-rule SG connectivity ownership, app IAM boundaries, KMS/GuardDuty/WAF and private egress compatibility |
| **C5 — Verification and handoff** | Not started | Actual Terraform dependency-graph review, backward-compatible synthetic consumer, negative security tests specification, independent review and M0-D handoff |

**Do not treat C1 as completed** by merging this initial design PR. The remaining checkpoints and their separate implementation acceptance are not in scope here.

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

The foundation publishes values only **after its protected Apply**. Application Terraform reads the resulting contract; foundation Terraform never reads application outputs. One SSM parameter has one Terraform owner in the foundation state. The application must not create, update or delete that parameter.

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
    "compute_private_subnet_ids": ["<private-subnet-az-a>", "<private-subnet-az-b>"],
    "ingress_public_subnet_ids": ["<public-subnet-az-a>", "<public-subnet-az-b>"],
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
    "engine_version": "<observed-engine-version>",
    "staging_run_state_eligible": false,
    "dedicated_to_application": false
  },
  "ecs": {
    "cluster_name": "<ecs-cluster-name>",
    "cluster_arn": "<ecs-cluster-arn>",
    "guardduty_runtime_monitoring_expected": false,
    "guardduty_agent_ecr_repository_arn": null
  },
  "ecr_repositories": {},
  "security": {
    "logs_kms_key_arn": "<logs-kms-arn>",
    "secrets_kms_key_arn": "<secrets-kms-arn>"
  }
}
```

A production contract should never expose an application-controlled `staging_run_state_eligible=true` flag. Both lifecycle gates default to `false` and can be set only through **independently approved, foundation-owned configuration** following a documented dedicated-use review. M0-C3/D must validate that the two conditions are true **and** that the actual instance ARN/account/Region match before enabling the controller or granting Start/Stop rights.

When `ecs.guardduty_runtime_monitoring_expected` is `true`, `ecs.guardduty_agent_ecr_repository_arn` must be an exact, non-null regional AWS-owned repository ARN published by the foundation; otherwise the application must fail closed rather than widen ECR permissions or reconstruct a regional account map. When monitoring is disabled, the ARN is `null`. The resolved ARN is **not** one of the application ECR repositories. M0-D must verify that task execution-role agent image pull grants are read-only and scoped to this exact ARN, with no wildcard repository substitution.

**Exact shape is proposed, not ratified.** M0-C1 review should decide whether subnets should also be keyed by AZ and whether the contract should encode supported capabilities separately from currently configured outputs. The foundation revision must be a reviewed, stable value, not a volatile `timestamp()` field that causes a plan diff on every run. A data change requires a protected foundation publication and an application re-plan.

### 3. Source and gap inventory

| Proposed field | Existing source | Gap / owner |
|---|---|---|
| Account, Region, environment, revision | Environment/root inputs, `aws_caller_identity`, `data.aws_region` and release CI | **Foundation:** publish verified identity/revision without exposing state |
| VPC, private/public subnets | `baseline/outputs.tf`: `vpc_id`, `network_topology.compute_private_subnet_ids_by_az`, `network_topology.ingress_public_subnet_ids_by_az` | **Foundation:** normalize deterministic lists/maps; app must not assume AZ order |
| Endpoint SG and S3 prefix list | `modules/vpc_endpoints/outputs.tf`: `interface_endpoints_sg_id`; root `s3_prefix_list_id` | **Foundation:** expose endpoint SG only in reviewed non-secret contract |
| RDS ID/ARN/endpoint/port/name/SG | `modules/storage/outputs.tf` `rds_configuration.identifier/arn`; root `rds_address`, `rds_port`, `rds_database_name`, `data_sg_id` | **Foundation:** purpose-built fields, not broad `rds_configuration` publication |
| RDS engine and lifecycle eligibility | Storage instance currently hardcodes `17.10`; no dedicated-use/run-state approval input exists | **C3:** new-instance engine input and protected staging eligibility; never downgrade PG17 in place |
| ECS cluster and monitoring | Root `ecs_cluster` output includes ARN/name and GuardDuty expected participation; `baseline/locals.tf` resolves `local.guardduty_fargate_agent_ecr_repository_arn` by supported Region, but the root does **not** publish that value when there is no deployable foundation service | **Foundation:** add an explicit resolved `guardduty_agent_ecr_repository_arn` contract field independent of `ecs_services`; require it when monitoring is enabled. **M0-D:** test exact agent-repository pull-only grants and reject missing/wildcard scopes |
| ECR repository inventory | Root `ecr_repositories` provides name/ARN/URL; null-digest service registration may still derive a repository | **Foundation:** identify and pin explicit repository ownership; avoid unintended ECR creation/removal |
| Logs and secrets CMK ARNs | Root `logs_cmk_arn`, `secrets_manager_cmk_arn` | **Foundation publishes references only; M0-D** enforces actual use permissions and KMS key policy |
| Mandatory role permissions boundary | Platform/bootstrap-governed, not currently a `baseline/outputs.tf` field | **M0-D:** publish/validate a platform-administered ceiling separately or via protected input; do not fabricate an ARN or let app CI control the boundary |
| ALB canonical hosted zone ID | App-owned ALB module currently exposes DNS name but not canonical hosted zone ID | **C4:** add generic ALB output or authorized lookup; **not** a foundation field because app owns its ALB |
| SG connectivity grants | Existing `modules/networking/security_policy` creates mandatory foundation rules | **C4/M0-D:** application-only rule interface or protected platform-owned grant; never call the entire foundation module from app state |

The schema must not include the foundation RDS master username/password/secret ARN, secret versions or values, full state contents, application tenant details, document identifiers, customer data, or deployer credentials. No fields may be added simply because a preexisting root output happens to expose them.

### 4. Producer and consumer controls

**Foundation producer (future implementation):**

- Creates/updates the exact contract parameter from allowlisted resource attributes and an explicitly reviewed contract revision. No app-dependent references or back edges.
- Owns the parameter and its write permissions under protected foundation Apply authority. Separate its read/write IAM from existing account bootstrap resources.
- Publishes only after the applicable foundation Plan/Apply completes; do not infer that a proposed contract is available before publication.
- Has deterministic serialization and schema-validation tests; no secret-bearing output can enter the document. A foundation destroy/retirement cannot proceed with an active application dependency.

**Application reader (future implementation):**

- Reads only the exact approved parameter by name through its own Plan role, with no `ssm:PutParameter`, recursive parameter-path read, baseline state-object read, or foundation IAM authority.
- Rejects absent/invalid/unsupported schema, wrong account/Region/environment, empty critical IDs, unsupported capability flags and unapproved lifecycle eligibility. Do not infer RDS operational availability from the published static contract; read current RDS status only through separately authorized observation.
- Binds the expected foundation revision/contract version to its reviewed plan. A foundation update must trigger an explicit compatibility review and a fresh application plan, not silently re-target running workloads.
- Keeps Plan read-only and Apply separately protected; if the contract read fails, the application pipeline **fails closed**.
- Does not automatically acquire KMS decryption, RDS configuration, foundation SG mutation, or Bedrock permissions merely by receiving ARNs.

**Security acceptance is deferred to M0-D:** IAM trust, S3 state-object and lockfile isolation, KMS restrictions, SG-grant authorization and exact-ARN RDS Start/Stop rights must be independently proven through positive and negative tests. This PR does not grant any such permissions.

### 5. C1 acceptance criteria (currently open)

- [ ] Owner approves the JSON schema, versioning/naming, publisher identity and allowed field inventory.
- [ ] Publication mechanism does not require foundation to consume application resources or application to read foundation state.
- [ ] Account/Region/revision/lifecycle flags fail closed under both synthetic positive and negative contracts.
- [ ] Missing endpoint SG, DB identity/engine-version, and resolved GuardDuty agent repository ARN output gaps have explicit implementation owners; monitoring-enabled consumers reject absent/wildcard agent ARNs.
- [ ] The mandatory boundary reference and app resource-grant scheme are assigned to M0-D without widening existing deployer roles.
- [ ] Existing baseline single-container workflows and resource addresses remain unaffected.
- [ ] CI and independent design review complete; no new AWS resources claimed.

## Handoff to C2–C5 and M0-D

**C2:** Design optional `containers` / `ecs_tasks` / `schedules` interfaces, per-container dependencies and distinct task/execution IAM. Preserve current single-container defaults and resource addresses.

**C3:** Preserve the baseline's PostgreSQL 17.10 default and qualify PostgreSQL 16 for **new** instances. Specify distinct application secrets and the owner-approved staging-only run-state controller. Require exclusive-use proof, stop/drain coordination, start-before-migrate, autoscaling controls and safe teardown (destroying the controller does not restart RDS; AWS may restart stopped RDS after seven days).

**C4:** Specify application-owned ALB/ACM/DNS resources and private ECS security rules without duplicating foundation security-policy rules. Preserve WAF/ALB logging/deletion safeguards, GuardDuty execution-role pulls, CMK-compatible secrets and 50 MiB upload handling.

**C5:** Verify the actual Terraform graph from representative configurations, no cross-state resource ownership duplication, and default behavior/resource-address compatibility for existing non-adopters. An architecture diagram is not a substitute for a graph test.

**M0-D:** Independently enforce app Plan/Apply/release scope, permissions boundaries, RDS Start/Stop, SG grants and KMS/S3 isolation. The owner-approved two-state design is not implementation permission.

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

**No Terraform changes, AWS deployment, published SSM parameter, live contract, or security qualification is claimed.**
