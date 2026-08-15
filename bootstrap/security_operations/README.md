# Security Operations (`bootstrap/security_operations`)

## Purpose

The `security_operations` bootstrap area contains the Terraform roots that establish the dedicated centralized security administration layer for `tf-secure-baseline`.

It is deployed in the `security-operations` AWS account, which is placed in the root-level `Security` OU and registered by the control plane as the delegated administrator for Security Hub CSPM and GuardDuty.

This layer is intentionally separate from both the AWS Organizations management account and the workload accounts.

---

## Responsibilities

The security-operations layer owns three distinct concerns:

| Substack | Purpose |
|---|---|
| `state/` | Creates the security-operations S3 Terraform state bucket and state CMK, then migrates its own state to that backend |
| `account/` | Creates the security-operations GitHub OIDC execution roles |
| `security_services/` | Configures centralized Security Hub CSPM, GuardDuty organization governance, and Security Hub V2 organization policy management |

The parent directory does not represent one Terraform root. Each subdirectory has its own backend, state, inputs, and lifecycle.

---

## Ownership Boundary

Centralized security is split deliberately between the control plane, the security-operations account, and the workload accounts.

### Control plane owns organization-level prerequisites

`bootstrap/control_plane/organizations` owns or establishes:

- AWS Organizations structure and account placement;
- the root-level `Security` and `Workloads` OU hierarchy;
- trusted service access required by centralized Security Hub and GuardDuty;
- Security Hub and GuardDuty delegated-administrator registration;
- GuardDuty malware-protection trusted service access;
- `SECURITYHUB_POLICY` enablement; and
- management-account prerequisites required for delegated Security Hub V2 organization-policy management.

### Security operations owns delegated-administrator configuration

`bootstrap/security_operations/security_services` owns:

- Security Hub CSPM administrator enablement;
- the Security Hub finding aggregator;
- CENTRAL Security Hub organization configuration;
- workload CSPM configuration policies and associations;
- the existing GuardDuty administrator detector and organization member enrollment;
- GuardDuty organization protection-plan configuration, including Runtime Monitoring;
- Security Hub V2 administrator enablement; and
- the Security Hub V2 organization policy attached to the `Workloads` OU.

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

For end-to-end deployment instructions, see `docs/quickstart.md`.

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

Do not destroy the state bucket while it contains the active state used to manage itself. Migrate the state to an independent backend or local state and retain an external backup before any intentional teardown.

---

## GitHub Actions

The current CI/CD model uses the `security-operations-plan` GitHub Environment for supported read-only or planning operations.

Current integration includes:

- the standalone `Terraform Plan` workflow for `bootstrap/security_operations/security_services`; and
- the `Export Security Operations Evidence` workflow.

Both use the security-operations GitHub Plan role through OIDC.

The generic workload Apply and Destroy workflows intentionally do **not** manage the security-operations layer. Central security has organization-wide blast radius and should be changed through a deliberately protected platform workflow or controlled operator execution rather than the workload lifecycle.

The `state` and `account` substacks are bootstrap/long-lived resources and should not be treated as routine deployment or destroy targets.

---

## Validation and Evidence

Centralized security has its own validation layer:

```bash
AWS_PROFILE=security-operations \
AWS_REGION=us-east-1 \
./scripts/validation/validate-security-operations.sh
```

Evidence can be exported with:

```bash
AWS_PROFILE=security-operations \
AWS_REGION=us-east-1 \
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

It does not replace control-plane validation of the complete Organizations topology, and it does not replace workload baseline validation of member-account realization.

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