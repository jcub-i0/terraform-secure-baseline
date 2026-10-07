# 🔐 IAM Identity Center (`bootstrap/control_plane/identity_center`)

## Purpose

Manages centralized workforce access across the AWS organization through IAM Identity Center.

This stack creates and assigns environment-specific SecOps groups and permission sets for:

- workload accounts: `dev`, `staging`, and `prod`;
- the centralized `security-operations` account.

The stack uses the reusable `modules/identity_center` module with two access models: one repeated workload model and one dedicated security-operations model.

This reference describes `v1.11.0-rc1` (`728166fa17bf42fe06bf540729c6aba1e70e05d5`). See [main.tf](main.tf), [variables.tf](variables.tf), and the [module reference](../../../modules/identity_center/README.md). Resource presence and assigned permission sets are not evidence that a person can perform the intended workflow.

---

## Scope

### This stack does

- Create workload Identity Center groups (permission-set names use lowercase environment suffixes):
  - `SecOps-Operator-Dev`
  - `SecOps-Operator-Staging`
  - `SecOps-Operator-Prod`
  - optional `SecOps-Analyst-*`
  - optional `SecOps-Engineer-*`
- Create the required security-operations administrator group:
  - `SecOps-Administrator`
- Create the corresponding `SecOps-Administrator-secops` permission set with `AdministratorAccess`.
- Optionally create security-operations Analyst and Engineer access:
  - `SecOps-Analyst-SecOps`
  - `SecOps-Engineer-SecOps`
- Assign enabled permission sets to their target AWS accounts.
- Reference workload-created customer-managed log-access policies by name.
- Construct each workload Operator policy ARN from the account/Region and the literal bus name `secops-bus`; see the RC1 mismatch below.

### This stack does not

- Create or manage Identity Center users or group membership.
- Create the referenced customer-managed IAM policies.
- Create workload application or baseline infrastructure.
- Create the workload SecOps EventBridge buses.
- Manage IAM users or long-lived access keys.
- Manage AWS Organizations account placement.

---

## Access Model

| Target | Required group display name | Optional groups | Operator |
|---|---|---|---|
| `dev` | `SecOps-Operator-Dev` | Analyst, Engineer | Enabled |
| `staging` | `SecOps-Operator-Staging` | Analyst, Engineer | Enabled |
| `prod` | `SecOps-Operator-Prod` | Analyst, Engineer | Enabled |
| `security-operations` | `SecOps-Administrator` | Analyst, Engineer | Disabled |

The corresponding permission sets are `SecOps-Operator-dev`, `SecOps-Operator-staging`, `SecOps-Operator-prod`, and `SecOps-Administrator-secops`. Optional workload permission sets use `SecOps-Analyst-<env>` / `SecOps-Engineer-<env>`; optional security-operations permission sets use the suffix `secops`, while their group display names end in `SecOps`.

### Workload accounts

Each entry in `identity_center_workloads` creates one module instance:

```text
module.identity_center_workload["dev"]
module.identity_center_workload["staging"]
module.identity_center_workload["prod"]
```

For every configured workload account:

- `SecOps-Operator` is always enabled.
- `SecOps-Analyst` is optional and defaults to disabled.
- `SecOps-Engineer` is optional and defaults to disabled.
- Group names are derived from the workload map key.
- The Operator ARN is constructed as `arn:aws:events:<primary_region>:<account_id>:event-bus/secops-bus`; it is not read from workload state.

The workload map keys are restricted to:

```text
dev
staging
prod
```

The root validation permits only these keys, but does not require all three to be present or require account IDs to be distinct. The complete-platform validator and the standalone Identity Center Plan workflow expect `dev`, `staging`, and `prod`. A Terraform-valid subset is therefore not automatically a supported complete-platform evidence configuration. Removing a key also removes that module instance's managed access resources.

### Operator bus identity in RC1

The actual caller and workload resource disagree:

| Authority | ARN resource portion |
|---|---|
| This root's `secops_event_bus_arn` argument | `event-bus/secops-bus` |
| [Workload automation](../../../modules/automation/main.tf), `aws_cloudwatch_event_bus.secops` | `event-bus/<name_prefix>-secops-bus` |

There is no root input for the bus name or `cloud_name` here. Changing the nested Region or account ID cannot repair the differing bus-name suffix. The module will put the supplied unprefixed ARN in its Operator inline policy, and the current control-plane validator does not compare this relationship.

Do not infer that all rollback requests must fail: the workload bus also has its own resource policy. In RC1 its rollback statement uses `Principal = "*"` with `events:source = custom.rollback`; it is not an Operator-principal allowlist. Effective authorization requires review of the identity and resource policies together. Neither an assignment PASS nor a successful event proves the intended Operator-only boundary. This documentation records the implementation mismatch; it does not fix either policy or authorize a new test event.

### Security-operations account

The security-operations account is configured separately through `identity_center_secops` because its access model differs from the workload accounts.

- `SecOps-Administrator` is always enabled.
- `SecOps-Operator` is disabled.
- `SecOps-Analyst` is optional and defaults to disabled.
- `SecOps-Engineer` is optional and defaults to disabled.

The required Administrator permission set uses a two-hour session and the AWS-managed `AdministratorAccess` policy. Its assignment target is the configured security-operations account rather than each workload account. This is not a narrow service-specific grant: central delegated-administrator capabilities can affect workload accounts through organization governance.

Optional Analyst/Engineer sessions are four hours. Both attach `SecurityAudit`, `ReadOnlyAccess`, and the required customer-managed log policies. Engineer additionally grants six Security Hub/EC2 response actions on `Resource = "*"` without resource-tag or approval conditions. Review the [exact module policy](../../../modules/identity_center/README.md#secops-engineer) before enabling that persona.

---

## Design Principles

- **Centralized administration**
  - Identity Center groups, permission sets, and account assignments are managed from the control-plane account.

- **Consistent workload configuration**
  - Workload accounts use one typed map and one `for_each` module call.

- **Separate security-operations access model**
  - Security-operations access remains a distinct object and module call rather than being forced into the workload model.

- **No circular Terraform dependencies**
  - Customer-managed policies are referenced by name rather than through workload remote state.
  - The referenced policies must exist in the target account before a permission-set attachment that uses them can be provisioned.

- **Explicit access expansion**
  - Analyst and Engineer access is disabled by default; their actual managed and wildcard response grants must be reviewed before opt-in.

---

## Provider, Region, and Backend

[providers.tf](providers.tf) pins Terraform `1.15.8` and AWS provider `6.66.0`, but does not declare an explicit AWS provider configuration. Use the control-plane administrative credentials and the Region of the existing Identity Center organization instance. The module discovers that instance; it does not create it or let this root select an instance ARN.

The two input objects below are the **entire root input interface**. There is no top-level `primary_region`, `state_region`, or `account_id`. A workload entry's `primary_region` only constructs its Operator policy ARN; it is not the Region of a separate per-workload Identity Center provider.

The backend is literal and independent:

```text
bucket: tf-secure-baseline-control-plane-state
key:    control-plane/identity-center.tfstate
region: us-east-1
```

Keep the existing backend coordinates and native S3 lockfile setting. The sibling state root's `state_region` does not rewrite these values. Follow the [state procedures](../state/README.md) for intentional bootstrap or migration.

## Deployment Workflow

### 1. Deploy initial Identity Center access

Apply this stack with workload Operator access enabled and optional Analyst and Engineer access disabled.

The workload configuration must still include the expected customer-managed policy names because those fields are required by the workload input schema, but those policies are not attached while Analyst and Engineer access remains disabled.

Workload Operator permission sets can be created before the target EventBridge buses exist because the module does not check bus existence. This is only an ordering allowance, not evidence of usable rollback access; review the differing RC1 bus names documented above before accepting the access path.

### 2. Deploy workload baselines

Each workload baseline creates the customer-managed IAM policies used by optional Analyst and Engineer permission sets, including:

- centralized logs S3 read-only access;
- centralized logs KMS decrypt access.

### 3. Enable optional roles

After the required policies exist in the target account:

1. set `enable_secops_analyst` and/or `enable_secops_engineer` to `true` for the target account;
2. confirm the configured policy names exactly match the policies in that account;
3. re-plan and re-apply this stack.

The security-operations policy-name fields are optional and may remain `null` while its Analyst and Engineer roles are disabled. If either is enabled, the module requires both names. This root does not pass `customer_managed_policy_path`, so all references use the module's `/` default. A policy elsewhere in the IAM path hierarchy is not selected by changing its name alone.

The security-services root does not create workload-style log-access policies for the security-operations account. Provision and review any needed policies in that target account through its actual policy owner before enabling optional personas; do not reference policies from a workload account as though they were local.

### 4. Plan and review the access change

Run from the repository root in a local named-profile session. Set the following values deliberately; `<...>` values are placeholders, not deployment defaults. The `${VAR:?message}` expressions below reject unset or empty variables. They do not establish that a supplied value is correct.

```bash
export AWS_PROFILE="control-plane"
export AWS_REGION="<identity-center-home-region>"
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

Use the schema examples below only as starting values. Preserve every account entry, role flag, and policy name required by the intended access configuration when editing a deployed stack.

---

## Inputs

### `identity_center_workloads`

Identity Center configuration keyed by workload environment. This input is required and has no default:

```hcl
map(object({
  account_id                   = string
  primary_region               = string
  enable_secops_analyst        = optional(bool, false)
  enable_secops_engineer       = optional(bool, false)
  logs_s3_readonly_policy_name = string
  logs_cmk_decrypt_policy_name = string
}))
```

Requirements:

- keys must be `dev`, `staging`, or `prod`;
- every account ID must contain exactly 12 digits;
- the two log-policy-name strings are required by the object type even while optional roles are disabled;
- policy names must match customer-managed policies at path `/` in the corresponding target account before an attachment that uses them is enabled.

The root does not validate Region syntax or uniqueness of account IDs, and it does not look up the policy documents. The Plan workflow has additional nonempty-string and complete-map checks. Its acceptance rules are not identical to the root's Terraform type/validation rules.

Example using synthetic 12-digit IDs; replace all accounts, Regions, and policy names with reviewed deployment values:

```hcl
identity_center_workloads = {
  dev = {
    account_id                     = "333333333333"
    primary_region                 = "us-east-1"
    enable_secops_analyst          = false
    enable_secops_engineer         = false
    logs_s3_readonly_policy_name   = "tf-secure-baseline-dev-CentralizedLogsS3ReadOnly"
    logs_cmk_decrypt_policy_name   = "tf-secure-baseline-dev-LogsKmsDecrypt"
  }

  staging = {
    account_id                     = "444444444444"
    primary_region                 = "us-east-1"
    enable_secops_analyst          = false
    enable_secops_engineer         = false
    logs_s3_readonly_policy_name   = "tf-secure-baseline-staging-CentralizedLogsS3ReadOnly"
    logs_cmk_decrypt_policy_name   = "tf-secure-baseline-staging-LogsKmsDecrypt"
  }

  prod = {
    account_id                     = "555555555555"
    primary_region                 = "us-east-1"
    enable_secops_analyst          = false
    enable_secops_engineer         = false
    logs_s3_readonly_policy_name   = "tf-secure-baseline-prod-CentralizedLogsS3ReadOnly"
    logs_cmk_decrypt_policy_name   = "tf-secure-baseline-prod-LogsKmsDecrypt"
  }
}
```

### `identity_center_secops`

Identity Center configuration for the security-operations account. This input is required and has no default:

```hcl
object({
  account_id                   = string
  enable_secops_analyst        = optional(bool, false)
  enable_secops_engineer       = optional(bool, false)
  logs_s3_readonly_policy_name = optional(string)
  logs_cmk_decrypt_policy_name = optional(string)
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

The standalone Identity Center Plan target reads these JSON variables from `control-plane-plan`. The workload Destroy workflow also consumes the consolidated access configuration for its separately reviewed Identity Center cleanup. A variable existing in a GitHub Environment does not imply a general-purpose administrative Apply workflow is implemented:

| GitHub variable | Terraform variable |
|---|---|
| `IDENTITY_CENTER_WORKLOADS` | `TF_VAR_identity_center_workloads` |
| `IDENTITY_CENTER_SECOPS` | `TF_VAR_identity_center_secops` |

Store raw JSON in GitHub without surrounding shell quotes. Set the provider/service Region to the Identity Center instance Region for these jobs; each nested workload Region remains an event-bus ARN input.

The [standalone Plan workflow](../../../.github/workflows/terraform-plan.yml) requires exactly the three workload keys and nonempty policy-name strings. Its plan is informational, not an artifact consumed by another Apply workflow. Do not replace a reviewed cleanup input with a partial one-account map: that can plan removal of access for omitted accounts.

Keep required-reviewer/branch protections and the actual OIDC role authority under separate review. [Production retirement](../../../docs/production-retirement.md) describes the cleanup approval sequence; removing optional workload personas removes their groups and assignments as well as policy attachments.

---

## Outputs

| Name | Description |
|---|---|
| `workload_permission_set_arns` | Permission-set ARN maps keyed by workload environment. |
| `secops_permission_set_arns` | Permission-set ARNs for the security-operations account. |

`workload_permission_set_arns` contains only configured workload entries; each inner map contains only enabled persona keys. `secops_permission_set_arns` always includes `secops-administrator` for this caller and includes optional personas only when enabled. These outputs do not identify assigned group principals or attest to policy contents.

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

The [control-plane validator](../../../scripts/validation/validate-control-plane.sh) checks the required named groups, describes output-backed permission-set ARNs, and requires at least one assignment for each queried target account/permission-set pair under its default strictness. It does **not** compare the assignment principal ID/type with the Terraform-created group, reject all extra assignments, inspect group membership, or compare the complete permission-policy/session settings. It also does not detect the Operator bus-name mismatch above.

Set `CHECK_OPTIONAL_SECOPS_GROUPS=true` to check optional Analyst/Engineer group names against the configured flags. `STRICT_IDENTITY_CENTER_ASSIGNMENTS=true` makes missing assignments fail; it does not make that check an exact membership or policy audit.

Run from the repository root after initializing all control-plane roots. This local example requires already-set named-profile and JSON context:

```bash
AWS_PROFILE="${AWS_PROFILE:?Set the control-plane profile}" \
AWS_REGION="${AWS_REGION:?Set the Identity Center service Region}" \
EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:?Set the management account ID}" \
EXPECTED_GITHUB_REPOSITORY="${EXPECTED_GITHUB_REPOSITORY:?Set owner/repo}" \
IDENTITY_CENTER_WORKLOADS="${IDENTITY_CENTER_WORKLOADS:?Set the workload JSON map}" \
IDENTITY_CENTER_SECOPS="${IDENTITY_CENTER_SECOPS:?Set the security-operations JSON object}" \
REQUIRE_STATE_STACK_REMOTE=true \
CHECK_OPTIONAL_SECOPS_GROUPS=true \
./scripts/validation/validate-control-plane.sh
```

The full validator expects all three workloads and security operations; it is not an isolated-root acceptance test during initial bootstrap. End-user SSO login, exact group/assignment inspection, policy review, and approved effective-access testing remain separate evidence. Do not publish a rollback event merely to verify permissions; it can invoke response automation.

---

## Important Notes

- Identity Center customer-managed policy attachments reference a policy by name and path in the target AWS account.
- A referenced policy must exist in the target account before AWS can provision the corresponding attachment successfully.
- IAM Identity Center provisions `AWSReservedSSO_*` roles into assigned target accounts.
- This stack manages groups, permission sets, and account assignments, but not users or group membership.
- Disabling a role removes the Terraform-managed group, permission set, policy attachments, and account assignment associated with that role.
- Changes to workload map keys alter Terraform module instance addresses. Treat key renames as state migrations rather than ordinary configuration changes.
- The security-operations account intentionally does not receive the workload Operator role.
- Do not destroy this root to retire one workload. Other accounts' human access and subsequent cleanup operations can depend on it.
- The root does not configure MFA, external IdP/SCIM, group membership, or a permission-set permissions boundary.
- An existing enabled persona's planned removal is an access revocation, not a documentation-only change.
