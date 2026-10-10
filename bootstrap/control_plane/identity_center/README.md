# 🔐 IAM Identity Center (`bootstrap/control_plane/identity_center`)

## Purpose

Manages centralized workforce access across the AWS organization through IAM Identity Center.

This stack creates and assigns environment-specific SecOps groups and permission sets for:

- workload accounts: `dev`, `staging`, and `prod`;
- the centralized `security-operations` account.

The stack uses the reusable `modules/identity_center` module with two access models: one repeated workload model and one dedicated security-operations model.

See [main.tf](main.tf), [variables.tf](variables.tf), and the [module reference](../../../modules/identity_center/README.md). Resource presence and assigned permission sets are not evidence that a person can perform the intended workflow.

---

## Scope

### This stack does

- Create the workload `SecOps-Operator-Dev`, `SecOps-Operator-Staging`, and `SecOps-Operator-Prod` groups and their permission sets.
- Create the `SecOps-Administrator` group and its `SecOps-Administrator-secops` permission set with `AdministratorAccess`.
- Assign those baseline-managed permission sets to the configured AWS accounts.
- Construct each workload Operator policy bus ARN from the selected partition, `cloud_name`, workload key, account ID, and Region.

### This stack does not

- Create or manage Identity Center users, group membership, or external workforce identity-provider configuration.
- Create customer-defined analyst, engineer, or other general workforce permission sets and assignments.
- Create workload application infrastructure, workload SecOps event buses, AWS accounts, or Organizations account placement.

---

## Access Model

| Target | Baseline-managed group | Operator |
|---|---|---|
| `dev` | `SecOps-Operator-Dev` | Enabled |
| `staging` | `SecOps-Operator-Staging` | Enabled |
| `prod` | `SecOps-Operator-Prod` | Enabled |
| `security-operations` | `SecOps-Administrator` | Disabled |

Permission-set names are `SecOps-Operator-dev`, `SecOps-Operator-staging`, `SecOps-Operator-prod`, and `SecOps-Administrator-secops`. Customer personnel beyond these baseline-specific operational identities are outside this stack's provisioning scope.

### Workload accounts

Each entry in `identity_center_workloads` creates one module instance:

```text
module.identity_center_workload["dev"]
module.identity_center_workload["staging"]
module.identity_center_workload["prod"]
```

For every configured workload account:

- `SecOps-Operator` is always enabled.
- Group names are derived from the workload map key.
- The Operator ARN uses the AWS provider's resolved partition: `arn:<partition>:events:<primary_region>:<account_id>:event-bus/<cloud_name>-<environment>-secops-bus`; it is not read from workload state.

The workload map keys are restricted to:

```text
dev
staging
prod
```

The root validation permits only these keys, but does not require all three to be present or require account IDs to be distinct. The complete-platform validator and the standalone Identity Center Plan workflow expect `dev`, `staging`, and `prod`. A Terraform-valid subset is therefore not automatically a supported complete-platform evidence configuration. Removing a key also removes that module instance's managed access resources.

### Operator bus identity

The caller and workload resource now use the same naming contract:

| Authority | ARN resource portion |
|---|---|
| This root's `secops_event_bus_arn` argument | `event-bus/<cloud_name>-<environment>-secops-bus` |
| [Workload automation](../../../modules/automation/main.tf), `aws_cloudwatch_event_bus.secops` | `event-bus/<name_prefix>-secops-bus`, where `name_prefix = <cloud_name>-<environment>` |

The root's `data.aws_partition.current` value, `cloud_name` (default
`tf-secure-baseline`), workload map key, account ID, and `primary_region`
determine each Operator policy ARN. This root does not query
workload state or confirm that the event bus exists; compare actual workload
naming and Region before accepting the access path.

The workload bus policy permits `custom.rollback` publication from matching
`AWSReservedSSO_SecOps-Operator-<environment>_*` IAM role ARNs and explicitly
denies nonmatching principals for that event source. A separate
`aws.securityhub` forwarding Allow is retained. The role name derives from
the permission-set name, not the configurable Identity Center group name.
Validate deployed group membership and positive/negative access; the handler
does not authenticate the supplied approver and ticket fields.

### Security-operations account

The security-operations account is configured separately through `identity_center_secops`. `SecOps-Administrator` is enabled and `SecOps-Operator` is disabled. The Administrator permission set has a two-hour session and attaches AWS-managed `AdministratorAccess`, so organization-governance impact and membership must be reviewed separately.

---

## Design Principles

- **Centralized baseline access:** Identity Center groups, permission sets, and assignments for Operator and Administrator are managed from the control-plane account.
- **Consistent workload model:** Workload accounts use one typed map and one `for_each` module call.
- **Distinct administration model:** Security-operations Administrator access is separate from workload Operator access.
- **Customer-owned workforce access:** Customers choose and provision their own investigative, engineering, and other staff identities/permissions. Workload-created log-access IAM policies can be used separately without any attachment by this stack.

---

## Provider, Region, and Backend

[providers.tf](providers.tf) pins Terraform `1.15.8` and AWS provider `6.66.0`, but does not declare an explicit AWS provider configuration. Use the control-plane administrative credentials and the Region of the existing Identity Center organization instance. The module discovers that instance; it does not create it or let this root select an instance ARN.

The root has two required input objects: `identity_center_workloads` and `identity_center_secops`. `cloud_name` is optional and defaults to `tf-secure-baseline`. There is no top-level `primary_region`, `state_region`, or `account_id`. Each workload entry's `primary_region` is an input to its Operator policy ARN, not a per-workload provider Region. Match `cloud_name` to the values used by the workload roots.

The backend is literal and independent:

```text
bucket: tf-secure-baseline-control-plane-state
key:    control-plane/identity-center.tfstate
region: us-east-1
```

Keep the existing backend coordinates and native S3 lockfile setting. The sibling state root's `state_region` does not rewrite these values. Follow the [state procedures](../state/README.md) for intentional bootstrap or migration.

## Deployment Workflow

### 1. Deploy baseline-managed identities

Configure the workload `SecOps-Operator` assignments and the security-operations `SecOps-Administrator` assignment. The former can be created before the target workload EventBridge buses because the operator policy uses a constructed ARN. Verify the final ARN, group membership, and authorized/denied event publication after deployment.

### 2. Configure customer workforce identities separately

This stack does not create customer analyst or engineer roles. Customers manage any additional Identity Center groups, permission sets, and assignments separately. Workload-created centralized-log read and KMS decrypt policies remain available to customers but are not automatically attached to any staff permissions here.

### 3. Plan and review the access change

Run from the repository root in a local named-profile session. Set the following values deliberately; `<...>` values are placeholders, not deployment defaults. The `${VAR:?message}` expressions below reject unset or empty variables. They do not establish that a supplied value is correct.

```bash
export AWS_PROFILE="control-plane"
export AWS_REGION="<identity-center-home-region>"
export AWS_DEFAULT_REGION="$AWS_REGION"
export EXPECTED_ACCOUNT_ID="<12-digit-account-id>"
```

Prepare and review this root's local input file before planning. Do not overwrite an existing `terraform.tfvars` with an example. For an adopted deployment, retain all required account entries and review permission-set removals explicitly; dropping a configured workload key can remove its Operator access.

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
  root="bootstrap/control_plane/identity_center"
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

Use the schema examples below only as starting values. Preserve every workload account entry and reviewed Operator bus identity when editing a deployed stack.

---

## Inputs

### `cloud_name`

Optional cloud naming value, defaulting to `tf-secure-baseline`. Set it to the same `cloud_name` used by the workload roots so the Operator bus name resolves to `<cloud_name>-<environment>-secops-bus`. Terraform rejects empty or whitespace-only values.

### `identity_center_workloads`

Identity Center configuration keyed by workload environment. This input is required and has no default:

```hcl
map(object({
  account_id     = string
  primary_region = string
}))
```

Requirements:

- keys must be `dev`, `staging`, or `prod`;
- every account ID must contain exactly 12 digits;

The root does not validate Region syntax or uniqueness of account IDs. The Plan workflow also checks that the workload map contains exactly dev, staging, and prod; its acceptance rules are not identical to Terraform's root input checks.

Example using synthetic 12-digit IDs; replace the account IDs and Regions with reviewed deployment values:

```hcl
cloud_name = "tf-secure-baseline"

identity_center_workloads = {
  dev = {
    account_id     = "333333333333"
    primary_region = "us-east-1"
  }

  staging = {
    account_id     = "444444444444"
    primary_region = "us-east-1"
  }

  prod = {
    account_id     = "555555555555"
    primary_region = "us-east-1"
  }
}
```

### `identity_center_secops`

Identity Center configuration for the security-operations account. This input is required and has no default:

```hcl
object({
  account_id = string
})
```

The account ID must contain exactly 12 digits.

Minimal example:

```hcl
identity_center_secops = {
  account_id = "222222222222"
}
```

---

## GitHub Actions Variables

The standalone Identity Center Plan target reads these JSON variables from `control-plane-plan`. The workload Destroy workflow no longer runs a dedicated Identity Center cleanup job; it retains a separately reviewed workload destroy plan and Apply approval. A variable existing in a GitHub Environment does not imply a general-purpose administrative Apply workflow is implemented:

| GitHub variable | Terraform variable |
|---|---|
| `CLOUD_NAME` | `TF_VAR_cloud_name` |
| `IDENTITY_CENTER_WORKLOADS` | `TF_VAR_identity_center_workloads` |
| `IDENTITY_CENTER_SECOPS` | `TF_VAR_identity_center_secops` |

Store raw JSON in GitHub without surrounding shell quotes. Set the provider/service Region to the Identity Center instance Region for these jobs; each nested workload Region remains an event-bus ARN input.

The [standalone Plan workflow](../../../.github/workflows/terraform-plan.yml) requires exactly the three workload keys with valid account IDs and nonempty Regions. Its plan is informational, not an artifact consumed by another Apply workflow. Omitting a configured workload from a Terraform input map can plan removal of that workload's Operator resources.

Keep required-reviewer/branch protections and the actual OIDC role authority under separate review. [Production retirement](../../../docs/production-retirement.md) documents the remaining workload destruction gates and separate administrative obligations.

---

## Migration: removal of customer workforce personas

Earlier versions optionally managed `SecOps-Analyst` and `SecOps-Engineer` groups, permission sets, and assignments. These are no longer provided by this stack. If previously enabled, applying the new configuration will plan access removal. Review those destroys, confirm replacement customer-managed access where needed, and do not mistake this for a non-disruptive documentation change.

Remove retired persona flags and log-policy-name fields from `IDENTITY_CENTER_WORKLOADS`, `IDENTITY_CENTER_SECOPS`, and local Terraform variable files. Terraform object conversion may otherwise discard unrecognized fields without warning. Keep the configured workload map and Operator roles intact. Workload log-read IAM policies still exist in the baseline but are not attached to a workforce permission set here.

---

## Outputs

| Name | Description |
|---|---|
| `workload_permission_set_arns` | Permission-set ARN maps keyed by workload environment. |
| `secops_permission_set_arns` | Permission-set ARNs for the security-operations account. |

`workload_permission_set_arns` contains only configured workload entries with the `secops-operator` key. `secops_permission_set_arns` includes only `secops-administrator` for this caller. These outputs do not identify assigned group principals or attest to policy contents.

Example workload output shape:

```hcl
workload_permission_set_arns = {
  dev     = { /* enabled permission sets */ }
  staging = { /* enabled permission sets */ }
  prod    = { /* enabled permission sets */ }
}
```

---

## Validation

The [control-plane validator](../../../scripts/validation/validate-control-plane.sh) checks the required named groups, describes output-backed permission-set ARNs, and requires at least one assignment for each queried target account/permission-set pair under its default strictness. It does **not** compare assignment principals to the Terraform-created group, reject unexpected assignments, inspect group membership, or compare complete permission-policy/session settings. It also does not verify the Operator ARN against the live bus policy; inspect both independently.

`STRICT_IDENTITY_CENTER_ASSIGNMENTS=true` makes missing assignments fail; it does not make that check an exact membership or policy audit.

Run from the repository root after initializing all control-plane roots. This local example requires already-set named-profile and JSON context:

```bash
AWS_PROFILE="${AWS_PROFILE:?Set the control-plane profile}" \
AWS_REGION="${AWS_REGION:?Set the Identity Center service Region}" \
EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:?Set the management account ID}" \
EXPECTED_GITHUB_REPOSITORY="${EXPECTED_GITHUB_REPOSITORY:?Set owner/repo}" \
IDENTITY_CENTER_WORKLOADS="${IDENTITY_CENTER_WORKLOADS:?Set the workload JSON map}" \
IDENTITY_CENTER_SECOPS="${IDENTITY_CENTER_SECOPS:?Set the security-operations JSON object}" \
REQUIRE_STATE_STACK_REMOTE=true \
./scripts/validation/validate-control-plane.sh
```

The full validator expects all three workloads and security operations; it is not an isolated-root acceptance test during initial bootstrap. End-user SSO login, exact group/assignment inspection, policy review, and approved effective-access testing remain separate evidence. Do not publish a rollback event merely to verify permissions; it can invoke response automation.

---

## Important Notes

- The baseline does not attach customer workforce IAM policies through Identity Center; clients manage those permissions independently.
- IAM Identity Center provisions `AWSReservedSSO_*` roles into assigned target accounts.
- This stack manages groups, permission sets, and account assignments, but not users or group membership.
- Removing or disabling a baseline-managed Operator/Administrator persona revokes its group, permission set, and account assignment.
- Changes to workload map keys alter Terraform module instance addresses. Treat key renames as state migrations rather than ordinary configuration changes.
- The security-operations account intentionally does not receive the workload Operator role.
- Do not destroy this root to retire one workload. Other accounts' human access and subsequent cleanup operations can depend on it.
- The root does not configure MFA, external IdP/SCIM, group membership, or a permission-set permissions boundary.
- Upgrading from an earlier version that enabled the removed Analyst/Engineer personas will plan their removal; inventory and migrate affected access before Apply.
