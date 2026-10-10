# 🧭 Control Plane (`bootstrap/control_plane`)

## Purpose

The control plane is the centralized governance and access layer for `tf-secure-baseline`. It is deployed in the AWS Organizations management account and manages the organization structure, centralized workforce access, control-plane CI/CD roles, and control-plane Terraform state.

It does **not** deploy workload application infrastructure or own the delegated administrator-side configuration of centralized security services.

`bootstrap/control_plane` is a directory of independent roots, not itself a Terraform deployment root. Use the repository-root paths below.

---

## Substacks

The control plane contains four independently managed Terraform roots:

| Substack | Purpose |
|---|---|
| `state/` | Creates the control-plane S3 state bucket and KMS key, then an operator migrates its state into that backend with `scripts/bootstrap/migrate-state-stack.sh`. |
| `account/` | Creates the OIDC provider/Plan role when enabled and the optional Apply role; does not create GitHub Environment protections. |
| `organizations/` | Manages the AWS Organization structure and the management-account prerequisites for centralized Security Hub and GuardDuty administration. |
| `identity_center/` | Manages IAM Identity Center groups, permission sets, and account assignments for workload and security-operations accounts. |

### State

The `state` substack follows the same two-phase bootstrap model as the other state stacks:

1. apply locally without an active `backend.tf`;
2. create the S3 state bucket and KMS key;
3. migrate the local state with `scripts/bootstrap/migrate-state-stack.sh`;
4. use the S3 backend with native lockfiles (`use_lockfile = true`).

The control-plane state stack does not use a DynamoDB lock table. Migration is an operator action, not an automatic side effect of applying its Terraform configuration. See the [state substack reference](state/README.md).

### Account

The `account` substack creates the GitHub OIDC roles used by control-plane automation. Keeping these roles outside the managed-resource graphs avoids including them in a normal workload destroy. It does not prevent an explicit account-root change from removing them. Plan has bucket-wide state-object write/delete grants; Apply attaches `AdministratorAccess`. See the [account reference](account/README.md) rather than inferring permissions from role names.

### Organizations

The `organizations` substack owns the AWS Organizations structure and management-account security prerequisites. It manages:

- AWS Organizations in `ALL` features mode;
- `Workloads`, `NonProd`, `Prod`, and `Security` OUs;
- Security Hub trusted access and delegated-administrator registration when enabled;
- GuardDuty trusted access and delegated-administrator registration when enabled;
- GuardDuty Malware Protection trusted service access;
- Security Hub V2 `SECURITYHUB_POLICY` enablement and management-account delegation prerequisites.

The three delegated-security enablement flags in [organizations/variables.tf](organizations/variables.tf) default to false. Deliberately select the intended centralized-security rollout; the empty organization example variable file does not enable it. GuardDuty Malware Protection trusted access is separately unconditional in the resource definitions.

The actual centralized Security Hub CSPM, GuardDuty organization protection-plan, and Security Hub V2 workload policy configuration is owned by:

```text
bootstrap/security_operations/security_services
```

### Identity Center

The `identity_center` substack manages centralized workforce access across the workload and security-operations accounts.

The current required access model includes:

```text
SecOps-Operator-Dev
SecOps-Operator-Staging
SecOps-Operator-Prod
SecOps-Administrator
```

Only baseline-specific workload Operator and security-operations Administrator access is provisioned here; customers manage other workforce roles. The root consumes `identity_center_workloads` and `identity_center_secops`, not the old individual workload account-ID inputs. Workload module instances follow the configured map keys; the complete platform validation path expects dev, staging, prod, and the security-operations configuration.

This Terraform root looks up an existing Identity Center instance through its module; enabling the account's Identity Center service is a prerequisite, not an account-vending operation. Use the [quickstart](../../docs/quickstart.md) and [Identity Center root](identity_center/README.md) for the detailed access sequence.

---

## Organization Model

The expected organization hierarchy is:

```text
Root
├── Workloads
│   ├── NonProd
│   │   ├── dev
│   │   └── staging
│   └── Prod
│       └── prod
└── Security
    └── security-operations
```

The `organizations` Terraform root creates and manages the OU hierarchy, but it does not create AWS accounts or perform account invitations. Account placement must already be established through the adopted account-management process and is validated separately by control-plane validation.

---

## Region, backend, and toolchain context

All four control-plane roots pin Terraform **1.15.8** and AWS provider **6.66.0**. Their provider configuration is not uniform:

| Root | Region authority |
|---|---|
| `bootstrap/control_plane/state` | Explicit provider configuration uses `state_region` for state-resource provisioning. |
| `bootstrap/control_plane/account` | Explicit provider configuration uses required `primary_region`; the data-source postcondition checks agreement. |
| `bootstrap/control_plane/organizations` | No explicit AWS provider configuration or top-level `primary_region` input; select the provider Region through the execution context. |
| `bootstrap/control_plane/identity_center` | Same implicit provider configuration; nested workload `primary_region` values build workload policy ARNs, not the management-account provider selection. |

Select the control-plane profile and intended Region explicitly for administrative execution. `AWS_REGION` and `AWS_DEFAULT_REGION` should agree. Do not assume `TF_VAR_primary_region` configures a root that does not declare that input, or that changing nested workload Regions moves Identity Center.

Each S3 backend also has an independent literal `region`, bucket, and key. The account backend is `control-plane/account.tfstate`; Organizations and Identity Center use their own objects. Updating an IAM bucket ARN or an execution Region does not migrate those objects. Retain the tracked lockfiles and the initial-local-state/migration boundary.

## Ownership Boundary

The control plane owns **management-account governance prerequisites**. The security-operations account owns **delegated administrator-side security configuration**.

```text
control-plane / organizations
    |
    +--> AWS Organizations structure
    +--> trusted service access
    +--> delegated administrator registration
    +--> SECURITYHUB_POLICY prerequisites
    |
    v
security-operations / security_services
    |
    +--> Security Hub CSPM central configuration
    +--> GuardDuty organization configuration and protection plans
    +--> Security Hub V2 workload organization policy
```

This boundary keeps AWS Organizations authority in the management account while placing operational security-service administration in the dedicated security-operations account.

---

## Design Principles

- **Centralized governance, decentralized workloads**
  - The control plane defines organization structure and human access.
  - Workload stacks deploy environment infrastructure.
  - The security-operations stack administers centralized security services.

- **No circular Terraform dependencies**
  - Baseline-managed Identity Center identities do not depend on workload-created log-access policies.
  - Customers independently define any workforce permissions requiring those policies.

- **Bootstrap before automation**
  - State and OIDC execution roles are established before CI/CD depends on them.

- **Multi-account by default**
  - Governance, security administration, and workloads are separated across `control-plane`, `security-operations`, `dev`, `staging`, and `prod` accounts.

---

## Validation

Control-plane validation owns checks for the expected five-account Organizations topology and selected management-account prerequisites, including:

- organization and OU structure;
- expected workload and security-operations account placement;
- Security Hub and GuardDuty trusted access;
- delegated-administrator registration;
- Security Hub V2 `SECURITYHUB_POLICY` prerequisites;
- required IAM Identity Center groups, permission sets, and assignments.

Run from the repository root only after the four roots are initialized and applied as required. This local example assumes a selected named profile, service Region, expected account/repository, and the reviewed consolidated Identity Center JSON values. `${VAR:?message}` stops before execution when a required value is missing; it does not check that the value is correct.

```bash
AWS_PROFILE="${AWS_PROFILE:?Set the control-plane profile}" \
AWS_REGION="${AWS_REGION:?Set the control-plane service Region}" \
EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:?Set the management account ID}" \
EXPECTED_GITHUB_REPOSITORY="${EXPECTED_GITHUB_REPOSITORY:?Set owner/repo}" \
IDENTITY_CENTER_WORKLOADS="${IDENTITY_CENTER_WORKLOADS:?Load reviewed workload JSON}" \
IDENTITY_CENTER_SECOPS="${IDENTITY_CENTER_SECOPS:?Load reviewed security-operations JSON}" \
REQUIRE_STATE_STACK_REMOTE=true \
./scripts/validation/validate-control-plane.sh
```

For generated evidence, use the **Export Control Plane Evidence** workflow through `control-plane-plan`, or its local exporter with the same context. The exporter runs its validator again; it does not package a previous terminal run. GitHub OIDC does not require a named `AWS_PROFILE`.

Default strict account-placement and Identity Center assignment checks remain separate from end-user login, effective permissions, and GitHub approval settings. Review warnings and retain the exact source/deployment revision separately. A PASS is not a complete organization security assessment or proof of workload/runtime recovery.

---

## Supported automation and retirement boundary

The standalone [Terraform Plan workflow](../../.github/workflows/terraform-plan.yml) supports `control-plane-organizations` and `control-plane-identity-center` through `control-plane-plan`. It does not plan the `account` or `state` root, and its informational plan is not the saved plan consumed by the workload Apply workflow.

Keep account/state administration separate from workload changes. The workload Destroy workflow depends on the control-plane roles and Identity Center for its separately reviewed optional-policy cleanup. Do not destroy the entire Identity Center stack before those dependent workflows finish. Final workload-destroy approval occurs after that separate cleanup; rejecting a later approval does not undo earlier mutations. See [production retirement](../../docs/production-retirement.md).

Full control-plane decommissioning is not an extension of the qualified workload retirement path. The Organization and state resources include literal destruction guards. Moving a state root off its own bucket is necessary for safe backend retirement but does not remove `prevent_destroy`; no automatic bypass is documented here.

## Summary

The control plane provides the stable governance foundation for `tf-secure-baseline`: protected Terraform state, CI/CD identities, AWS Organizations structure, centralized-security prerequisites, and IAM Identity Center access. Workload and security-service implementation remain in their respective accounts so foundational governance is isolated from day-to-day infrastructure changes.
