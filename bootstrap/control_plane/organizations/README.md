# 🏢 AWS Organizations (`bootstrap/control_plane/organizations`)

## Purpose

This Terraform root manages the AWS Organizations structure used by `tf-secure-baseline` and the management-account prerequisites required for centralized Security Hub and GuardDuty administration.

It runs in the AWS Organizations management (`control-plane`) account.

The authority is this root's [implementation](main.tf), [inputs](variables.tf), [outputs](outputs.tf), and [backend](backend.tf), not the names of its feature flags alone.

---

## Scope

### This stack manages

- The AWS Organization in `ALL` features mode.
- Organizational Units:
  - `Workloads`
  - `NonProd` under `Workloads`
  - `Prod` under `Workloads`
  - `Security` at the organization root
- Security Hub trusted service access when delegated administration is enabled.
- The `security-operations` account as Security Hub delegated administrator when enabled.
- GuardDuty trusted service access when delegated administration is enabled.
- GuardDuty Malware Protection trusted service access, unconditionally, including when all three feature flags are `false`.
- The `security-operations` account as GuardDuty delegated administrator when enabled.
- Security Hub V2 organization-management prerequisites when enabled:
  - the `SECURITYHUB_POLICY` organization policy type;
  - the `securityhubv2.amazonaws.com` service-linked role;
  - an AWS Organizations resource policy allowing the security-operations account to manage Security Hub organization policies.

### This stack does not manage

- AWS account creation or account invitations.
- Workload or security-operations account placement operations.
- Service Control Policies (SCPs).
- Security Hub CSPM configuration policies or workload associations.
- GuardDuty organization protection-plan settings.
- The Security Hub V2 workload organization policy itself.
- Workload infrastructure.

Delegated administrator-side security configuration belongs to:

```text
bootstrap/security_operations/security_services
```

---

## Organization Structure

The managed OU hierarchy is:

```text
Root
├── Workloads
│   ├── NonProd
│   └── Prod
└── Security
```

The expected account placement is:

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

The OU resources are Terraform-managed. Account creation and placement are intentionally outside this stack; control-plane validation verifies the expected live placement.

---

## AWS Organization Ownership

The organization resource includes:

```hcl
resource "aws_organizations_organization" "main" {
  feature_set = "ALL"

  enabled_policy_types = var.enable_securityhub_v2_organization_management ? [
    "SECURITYHUB_POLICY",
  ] : []

  lifecycle {
    prevent_destroy = true

    ignore_changes = [
      aws_service_access_principals,
    ]
  }
}
```

The literal `prevent_destroy` is on the organization resource, not on every OU, registration, service-access resource, or delegation policy in this root. It does not prevent in-place governance changes. Workload `production_retirement_mode` does not remove this guard.

`enabled_policy_types` is a configured list, not an additive merge with all currently enabled organization policy types. In an existing organization, inspect the plan for changes to other policy types even though this stack does not create SCP policy documents. Do not equate “does not manage SCPs” with “cannot affect policy-type enablement.”

The resource also ignores direct drift in `aws_service_access_principals` because trusted service access is managed through dedicated `aws_organizations_aws_service_access` resources rather than the aggregate organization attribute.

If adopting this stack into an AWS Organization that already exists outside Terraform state, reconcile/import the existing organization before applying changes. Review ownership of existing matching OUs, delegated-administrator registrations, service-access resources, the V2 service-linked role, and the Organizations resource policy as well. Do not assume importing only the organization reconciles every resource in this root.

The V2 `aws_organizations_resource_policy` supplies its complete policy content; it does not merge unrelated pre-existing delegation statements. Review the current policy and proposed replacement before adopting or changing this resource.

---

## Centralized Security Prerequisites

### Security Hub CSPM

When `enable_securityhub_delegated_administrator = true`, this stack:

1. enables AWS Organizations trusted access for `securityhub.amazonaws.com`;
2. designates the existing `security-operations` account as the Security Hub delegated administrator.

The Security Hub CSPM organization configuration and per-workload configuration policies are managed from the security-operations account, not here.

### GuardDuty

When `enable_guardduty_delegated_administrator = true`, this stack:

1. enables AWS Organizations trusted access for `guardduty.amazonaws.com`;
2. designates the existing `security-operations` account as GuardDuty delegated administrator.

Trusted service access for:

```text
malware-protection.guardduty.amazonaws.com
```

is enabled **without a `count` or feature-flag condition**. Thus an all-flags-false plan still includes this trusted-access resource alongside the organization and four OUs. Trusted access does not by itself prove the EBS protection feature or an actual scan is enabled in every member account.

GuardDuty organization enrollment and protection-plan configuration are managed from the security-operations account.

### Security Hub V2

When `enable_securityhub_v2_organization_management = true`, this stack enables the management-account prerequisites for Security Hub V2 organization policy management:

- `SECURITYHUB_POLICY` is enabled as an Organizations policy type;
- the Security Hub V2 service-linked role is created;
- an Organizations resource policy grants the security-operations account the read and policy-management permissions required for `SECURITYHUB_POLICY` resources.

The Security Hub V2 organization policy attached to the `Workloads` OU is created by `bootstrap/security_operations/security_services`.

The delegation policy here grants the resolved security account principal organization-read permissions, policy-read permissions, policy management, and policy tagging. The policy-management resource patterns include all roots, OUs, and accounts in the organization plus its `securityhub_policy/*` resources; they are not restricted to the one `Workloads` OU. Policy read/management use `StringLikeIfExists` on `organizations:PolicyType = SECURITYHUB_POLICY`. Record those actual scopes rather than describing this as a Workloads-only authorization boundary.

The three feature flags are independent inputs. A `depends_on` reference to Security Hub registration does not force its feature flag to `true`. The intended full central rollout enables the related prerequisites together; the code does not validate every supported combination.

---

## Security-Operations Account Requirement

The delegated-administrator resources resolve an existing AWS Organizations account named:

```text
security-operations
```

The name can be changed with `security_operations_account_name`, but the target account must already exist in the organization before centralized security administration is enabled.

This stack does not create that account. The resolver matches the account **name**, not a caller-supplied account ID, and does not filter that list to `ACTIVE` accounts. Verify the intended account's identity and status before enabling any consumer of the resolved ID.

The `check "security_operations_account"` assertion tests uniqueness only when `enable_securityhub_delegated_administrator` is true. It is not a separate GuardDuty/V2 uniqueness gate. A failed Terraform `check` assertion reports a warning and does not itself block Apply; expression evaluation, resource conditions, or AWS may fail independently. See the [Terraform check-block behavior](https://developer.hashicorp.com/terraform/language/block/check). This root also has no blocking expected-management-account input/precondition; verify caller identity independently before planning or applying.

---

## Inputs

| Variable | Type | Default | Purpose |
|---|---|---:|---|
| `enable_securityhub_delegated_administrator` | `bool` | `false` | Enables Security Hub trusted access and delegated-administrator registration. |
| `security_operations_account_name` | `string` | `security-operations` | Organization account name used for centralized security administration. |
| `enable_guardduty_delegated_administrator` | `bool` | `false` | Enables GuardDuty trusted access and delegated-administrator registration. |
| `enable_securityhub_v2_organization_management` | `bool` | `false` | Enables the Organizations prerequisites for centralized Security Hub V2 policy management. |

The feature flags default to `false` so the organization can be adopted and the delegated administrator account prepared before centralized security governance is enabled.

---

## Outputs

| Output | Purpose |
|---|---|
| `organization_id` | AWS Organizations organization ID. |
| `organization_root_id` | Organization root ID. |
| `organizational_unit_ids` | IDs for `Workloads`, `NonProd`, `Prod`, and `Security`. |
| `security_operations_account_id` | Name-resolved account ID; `null` when the resolver cannot select exactly one match. Not proof of active status or delegation. |
| `central_security_features_enabled` | Input booleans for the three prerequisite flags; not a live AWS health result. |
| `delegated_administrator_account_ids` | Object with `securityhub` and `guardduty`; each is the resource-backed admin account ID or `null` when its resource is absent. |

`organizational_unit_ids` uses the keys `workloads`, `nonprod`, `prod`, and `security`. `central_security_features_enabled` uses `securityhub_delegated_administrator`, `guardduty_delegated_administrator`, and `securityhub_v2_organization_management`. The output contract has six outputs; it does not expose the complete delegation policy or assert its effective permissions.

---

## Provider, Backend, and Administrative Lifecycle

[providers.tf](providers.tf) pins Terraform `1.15.8` and AWS provider `6.66.0`, but declares no explicit `provider "aws"` configuration. This root has no `primary_region`, `state_region`, `account_id`, or `cloud_name` input. Select the management-account credentials and service Region through the provider's execution context; a `TF_VAR_primary_region` alone is not a Region selector for this root.

The checked-in backend coordinates are:

```text
bucket: tf-secure-baseline-control-plane-state
key:    control-plane/organizations.tfstate
region: us-east-1
```

Service Region and backend Region are distinct. The sibling `state` root's `state_region` provisions its bucket/CMK; it does not rewrite this backend. Keep `use_lockfile = true` and a distinct key, and retain the existing backend when planning an established deployment. [State procedures](../state/README.md) cover deliberate bootstrap/migration.

The tracked `terraform.tfvars.example` in this root is empty. Copying it does not enable any central-security prerequisites. Existing central deployments must retain their explicitly selected feature flags when planning from a clean checkout.

This is long-lived administrative state, not a workload-retirement target. Removing trusted access, policy types, delegated administrators, or OUs can affect multiple accounts. The workload Destroy workflow does not authorize that work.

### Controlled local plan

Run from the repository root in a local named-profile session. Set the following values deliberately; `<...>` values are placeholders, not deployment defaults. The `${VAR:?message}` expressions below reject unset or empty variables. They do not establish that a supplied value is correct.

```bash
export AWS_PROFILE="control-plane"
export AWS_REGION="<management-service-region>"
export AWS_DEFAULT_REGION="$AWS_REGION"
export EXPECTED_ACCOUNT_ID="<12-digit-account-id>"
```

Prepare and review this root's local input file before planning. Do not overwrite an existing `terraform.tfvars` with an example. For an adopted deployment, retain its existing feature flags and configuration; omitted settings can select defaults that remove resources.

The following creates a saved plan, not an Apply. It assumes the intended backend already exists and its literal bucket/key/Region have been reviewed. Initialization is separate from the read-only validators.

```bash
(
  set -euo pipefail
  : "${AWS_PROFILE:?Set the named administrative profile}"
  : "${AWS_REGION:?Set the service Region}"
  : "${EXPECTED_ACCOUNT_ID:?Set the expected administrative account ID}"
  export AWS_PROFILE AWS_REGION
  export AWS_DEFAULT_REGION="$AWS_REGION"
  [[ "$EXPECTED_ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || {
    echo "Expected account ID must contain exactly 12 digits" >&2; exit 1;
  }
  actual_account="$(aws sts get-caller-identity --query Account --output text)"
  [[ "$actual_account" == "$EXPECTED_ACCOUNT_ID" ]] || {
    echo "AWS account mismatch; no Terraform operation was started" >&2; exit 1;
  }
  root="bootstrap/control_plane/organizations"
  terraform -chdir="$root" init -input=false -lockfile=readonly
  terraform -chdir="$root" validate
  umask 077
  plan_dir="$(mktemp -d "${TMPDIR:-/tmp}/tf-admin-plan.XXXXXX")"
  plan_file="$plan_dir/reviewed.tfplan"
  terraform -chdir="$root" plan -input=false -out="$plan_file"
  terraform -chdir="$root" show -no-color "$plan_file"
  printf 'Review and retain this saved plan securely: %s\n' "$plan_file"
)
```

Do not apply a plan with unresolved warnings, unexpected removals, or mismatched target identity. A later authorized Apply must use the reviewed binary plan with the same account and source context; this example does not invoke it. Saved plans can contain sensitive values and should not be committed or published. The generated temporary directory is deliberately retained for review and must be removed through the operator's evidence-retention process.

The standalone Terraform Plan workflow includes `control-plane-organizations` through `control-plane-plan`; its output is informational, not a saved artifact consumed by the workload Apply workflow. An existing OIDC role or GitHub Environment does not establish that branch restrictions or required reviewers are configured. Consult the [control-plane overview](../README.md) and review the actual workflow before an administrative change.

## Validation

The control-plane validator owns validation of this layer, including:

- AWS Organizations `ALL` features mode;
- root and OU topology;
- expected account identity and placement;
- Security Hub and GuardDuty trusted service access;
- delegated-administrator registration;
- `SECURITYHUB_POLICY` enablement when Security Hub V2 organization management is enabled.

Run from the repository root after the control-plane roots have been initialized. This validates the full control-plane layer, not only Organizations. The named-profile example assumes the expected management account and service Region are already selected:

```bash
AWS_PROFILE="${AWS_PROFILE:?Set the control-plane profile}" \
AWS_REGION="${AWS_REGION:?Set the control-plane service Region}" \
EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:?Set the management account ID}" \
EXPECTED_GITHUB_REPOSITORY="${EXPECTED_GITHUB_REPOSITORY:?Set owner/repo}" \
IDENTITY_CENTER_WORKLOADS="${IDENTITY_CENTER_WORKLOADS:?Set the workload JSON map}" \
IDENTITY_CENTER_SECOPS="${IDENTITY_CENTER_SECOPS:?Set the security-operations JSON object}" \
REQUIRE_STATE_STACK_REMOTE=true \
./scripts/validation/validate-control-plane.sh
```

`STRICT_ACCOUNT_OU_CHECKS` and `STRICT_IDENTITY_CENTER_ASSIGNMENTS` default to `true`. The complete-platform validator expects all three workload accounts plus security operations; an initial Organizations-only bootstrap is not a completed four-layer qualification. It does not execute account moves, administrative teardown, human access tests, or an exhaustive effective-permission evaluation of the delegation policy.

The **Export Control Plane Evidence** workflow produces the corresponding read-only evidence package. Review warnings and retain per-run source/account/Region provenance as described in the [evidence guide](../../../docs/assurance/validation-evidence-guide.md).

---

## Future Enhancements

Potential future governance extensions include:

- Service Control Policies (SCPs);
- automated account vending or placement;
- additional organization policy types;
- broader centralized governance controls.
