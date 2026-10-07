# Security Operations (`bootstrap/security_operations`)

## Purpose

The `security_operations` bootstrap area contains the Terraform roots that establish the dedicated centralized security administration layer for `tf-secure-baseline`.

It is deployed in the `security-operations` AWS account, which is placed in the root-level `Security` OU and registered by the control plane as the delegated administrator for Security Hub CSPM and GuardDuty.

This layer is intentionally separate from both the AWS Organizations management account and the workload accounts.

Implementation reference: `v1.11.0-rc1` (`728166fa17bf42fe06bf540729c6aba1e70e05d5`). The underscore in the directory name is not the standard logical `environment` value, which is `security-operations`.

---

## Responsibilities

The security-operations layer owns three distinct concerns:

| Substack | Purpose |
|---|---|
| `state/` | Creates the security-operations S3 Terraform state bucket and state CMK, then an operator migrates its state to that backend |
| `account/` | Creates the security-operations GitHub OIDC execution roles |
| `security_services/` | Configures centralized Security Hub CSPM, GuardDuty organization governance, and Security Hub V2 organization policy management |

The parent directory does not represent one Terraform root. Each subdirectory has its own backend, state, inputs, and lifecycle.

---

## Ownership Boundary

Centralized security is split deliberately between the control plane, the security-operations account, and the workload accounts.

### Control plane owns organization-level prerequisites

`bootstrap/control_plane/organizations` owns or establishes:

- AWS Organizations structure and delegated-security prerequisites; existing account membership/placement is established separately and validated by the control plane;
- the root-level `Security` and `Workloads` OU hierarchy;
- trusted service access required by centralized Security Hub and GuardDuty;
- Security Hub and GuardDuty delegated-administrator registration;
- GuardDuty malware-protection trusted service access;
- `SECURITYHUB_POLICY` enablement; and
- management-account prerequisites required for delegated Security Hub V2 organization-policy management.

### Security operations owns delegated-administrator configuration

`bootstrap/security_operations/security_services` owns:

- Security Hub CSPM administrator enablement;
- the Security Hub CSPM finding aggregator with `linking_mode = "NO_REGIONS"`;
- CENTRAL Security Hub organization configuration;
- workload CSPM configuration policies and associations;
- discovery of the existing GuardDuty administrator detector and, when enabled, organization member auto-enrollment;
- GuardDuty organization protection-plan configuration, including Runtime Monitoring;
- Security Hub V2 administrator enablement; and
- the Security Hub V2 organization policy attached to the `Workloads` OU.

The GuardDuty detector is a data source, not an `aws_guardduty_detector` resource owned by this stack; its lookup is unconditional. The appropriate administrator detector must already exist. Central configuration/policies are conditional on the rollout flags; do not infer their enablement merely from creating the account or finding the detector.

The V2 workload policy explicitly enables the selected provider Region, and the CSPM aggregator links no additional Regions. This is not a cross-Region recovery implementation. CSPM policy associations select existing active account names, and V2 attaches to the root-level OU named `Workloads`; neither mechanism creates or moves accounts.

### Workloads retain workload-local controls

The `dev`, `staging`, and `prod` workload stacks continue to own workload-local controls such as:

- AWS Config realization;
- Amazon Inspector;
- deterministic remediation and response automation;
- workload networking and VPC endpoints;
- logging, monitoring, KMS, backup, and patching; and
- the EC2 isolation and rollback implementation.

Workload Terraform defers local Security Hub CSPM, GuardDuty, and Security Hub V2 ownership when those services are centrally governed.

---

## Deployment Order

The security-operations layer is deployed after the control-plane organization prerequisites and before workload baselines:

```text
control-plane
    ↓
security-operations
    ↓
bootstrap-workloads
    ↓
workloads
```

Within `bootstrap/security_operations`:

```text
state -> account -> security_services
```

Recommended sequence:

1. Apply `bootstrap/security_operations/state` locally.
2. Migrate that state with `scripts/bootstrap/migrate-state-stack.sh security-operations`.
3. Apply `bootstrap/security_operations/account` to establish GitHub OIDC roles when enabled.
4. Apply `bootstrap/security_operations/security_services` after the control-plane delegated-administrator and Organizations prerequisites exist.
5. Deploy workload bootstrap and workload baseline stacks.
6. Validate centralized and workload-local realization through their separate evidence layers.

For end-to-end deployment instructions, see the [quickstart](../../docs/quickstart.md). Creating security-service resources can precede final workload-local health: policy associations and member-account controls still need validation after the workloads exist. Use source-configured rollout flags and actual evidence, not the diagram alone, to establish completion.

---

## State Lifecycle

The security-operations state stack follows the same two-phase bootstrap pattern as the other state stacks:

```text
initial local state
      ↓
create state S3 bucket + CMK
      ↓
migrate-state-stack.sh security-operations
      ↓
remote S3 state + native .tflock locking
```

The active `state/backend.tf` is intentionally ignored by Git. The tracked `backend.tf.migrated.example` represents the intended post-migration backend configuration.

Do not destroy the state bucket while it contains the active state used to manage itself. Migrate to an independent backend and retain an external backup before any separately approved backend decommissioning. That move does not remove the state module's literal bucket/CMK `prevent_destroy` guards; the workload retirement toggle does not apply to them.

State-resource provisioning uses `state_region`. The `account` and `security_services` providers use `primary_region`; their Region data sources enforce agreement with the configured provider. Each S3 backend independently declares its Region/bucket/key. The account key is `security-operations/account.tfstate`; state and security-services use distinct objects. Do not change an IAM ARN input and assume the backend migrated.

All three roots pin Terraform 1.15.8 and AWS provider 6.66.0. Retain their lockfiles. The [state reference](state/README.md) owns the migration/verification procedure; a tracked backend template is not evidence of completed migration.

---

## GitHub Actions

The current CI/CD model uses the `security-operations-plan` GitHub Environment for supported read-only or planning operations.

Current integration includes:

- the standalone `Terraform Plan` workflow for `bootstrap/security_operations/security_services`; and
- the `Export Security Operations Evidence` workflow.

Both use the security-operations GitHub Plan role through OIDC. Its trust is the `security-operations-plan` Environment subject, not the legacy Plan branch/PR inputs. The role attaches `ReadOnlyAccess` plus custom state-object write/delete, selected secret-read and conditional KMS grants; read-only use is not a read-only IAM permission boundary.

The generic workload Apply and Destroy workflows intentionally do **not** manage the security-operations layer. RC1 does not provide a matching generic centralized-service Apply path. Use the controlled operator procedure; any additional platform workflow is a separately designed extension, not an existing release capability.

The account example enables an Apply role, whose shared module attaches `AdministratorAccess`, but role availability does not imply a supported workflow consumes it. This account root exposes no Image Publisher interface. Configure any needed GitHub variables and Environment protections separately; the AWS account module does not create them.

The `state` and `account` substacks are bootstrap/long-lived resources and should not be treated as routine deployment or destroy targets.

---

## Validation and Evidence

Centralized security has its own validation layer. Run from the repository root with the `security_services` backend initialized and the stack applied. The local examples below require a selected named profile and the reviewed service Region/account ID. `${VAR:?message}` requires an existing non-empty value; it is not a placeholder to replace or a correctness check.

```bash
AWS_PROFILE="${AWS_PROFILE:?Set the security-operations profile}" \
AWS_REGION="${AWS_REGION:?Set the service Region}" \
EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:?Set the security-operations account ID}" \
./scripts/validation/validate-security-operations.sh
```

Evidence can be exported with:

```bash
AWS_PROFILE="${AWS_PROFILE:?Set the security-operations profile}" \
AWS_REGION="${AWS_REGION:?Set the service Region}" \
EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:?Set the security-operations account ID}" \
./scripts/validation/export-security-operations.sh
```

Generated evidence is written under:

```text
validation-results/security-operations/security-services/<timestamp>/
```

The Security Operations validator checks selected delegated-administrator state and directly required Organizations integration, including:

- Security Hub CSPM CENTRAL configuration and workload policy associations;
- GuardDuty organization enrollment, protection plans, and Runtime Monitoring;
- Security Hub V2 organization policy attachment and effective workload policy; and
- Terraform outputs and applied state for the `security_services` stack.

It does not replace control-plane checks for the expected Organizations topology, or workload baseline checks for member-account realization, ECS agent injection/coverage, RDS/Backup, or networking. It also does **not** constitute a dedicated validation of `security_operations/account` IAM trust/policies or the state root. Review those foundations independently; `validate-bootstrap.sh` is workload-only and does not accept `security-operations`.

The centralized validator compares the managed GuardDuty feature subset and checks that additional AWS-returned feature configurations remain disabled. That is policy evidence, not proof that a task is running or an event has been delivered. Review generated logs and warnings, preserve per-run provenance, and do not relabel earlier qualification as an exact-RC1 run.

The exporter runs the validator again. In GitHub OIDC jobs, leave named-profile setup out; temporary environment credentials are used. `REQUIRE_STATE_STACK_REMOTE` belongs to the bootstrap/control-plane evidence paths, not an automatic additional security-operations account audit.

---

## Related Documentation

Use the substack documentation for implementation-specific details:

```text
bootstrap/security_operations/state/README.md
bootstrap/security_operations/account/README.md
bootstrap/security_operations/security_services/README.md
```

Related platform documentation:

```text
docs/architecture-overview.md
docs/quickstart.md
docs/validation-checklist.md
docs/assurance/validation-evidence-guide.md
scripts/validation/README.md
```

---

## Summary

`bootstrap/security_operations` provides the dedicated administration boundary for organization-wide AWS security services without placing those responsibilities in either workload accounts or the Organizations management account.

The design keeps organization prerequisites, delegated-administrator configuration, and workload-local security controls in separate Terraform ownership domains while providing independent state, CI planning, validation, and evidence for the centralized security layer.
