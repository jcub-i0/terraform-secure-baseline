# 🔐 IAM Identity Center (`bootstrap/control_plane/identity_center`)

## Purpose

Manages centralized workforce access across the AWS organization through IAM Identity Center.

This stack creates and assigns environment-specific SecOps groups and permission sets for:

- workload accounts: `dev`, `staging`, and `prod`;
- the centralized `security-operations` account.

The stack uses the reusable `modules/identity_center` module but applies different access models to workload and security-operations accounts.

---

## Scope

### This stack does

- Create workload Identity Center groups and permission sets:
  - `SecOps-Operator-Dev`
  - `SecOps-Operator-Staging`
  - `SecOps-Operator-Prod`
  - optional `SecOps-Analyst-*` groups and permission sets
  - optional `SecOps-Engineer-*` groups and permission sets
- Create the security-operations administrator group and permission set:
  - `SecOps-Administrator`
- Optionally create security-operations Analyst and Engineer access:
  - `SecOps-Analyst-SecOps`
  - `SecOps-Engineer-SecOps`
- Assign enabled permission sets to their target AWS accounts.
- Reference workload-created customer-managed IAM policies by name.
- Configure each workload Operator permission set with its environment-specific SecOps EventBridge bus ARN.

### This stack does not

- Create the referenced customer-managed IAM policies.
- Create workload application or baseline infrastructure.
- Create the workload SecOps EventBridge buses.
- Manage IAM users or long-lived access keys.
- Manage AWS Organizations account placement.

---

## Access Model

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
- The SecOps EventBridge bus ARN is derived from the workload Region and account ID.

The workload map keys are restricted to:

```text
dev
staging
prod
```

### Security-operations account

The security-operations account is configured separately through `identity_center_secops` because its access model differs from the workload accounts.

- `SecOps-Administrator` is always enabled.
- `SecOps-Operator` is disabled.
- `SecOps-Analyst` is optional and defaults to disabled.
- `SecOps-Engineer` is optional and defaults to disabled.

---

## Design Principles

- **Centralized administration**
  - Identity Center groups, permission sets, and account assignments are managed from the control-plane stack.

- **Consistent workload configuration**
  - Workload accounts use one typed map and one `for_each` module call.

- **Separate security-operations access model**
  - Security-operations access remains a distinct object and module call rather than being forced into the workload model.

- **No circular Terraform dependencies**
  - Customer-managed policies are referenced by name rather than through workload remote state.
  - The referenced policies must exist in the target account before their permission-set attachments can be provisioned successfully.

- **Least-privilege expansion**
  - Analyst and Engineer access is disabled by default and enabled explicitly per account.

---

## Deployment Workflow

### 1. Deploy initial Identity Center access

Apply this stack with workload Operator access enabled and optional Analyst and Engineer access disabled.

The workload configuration must still include the expected customer-managed policy names because those fields are required by the workload input schema.

### 2. Deploy each workload baseline

The workload baseline creates the customer-managed IAM policies used by the optional Analyst and Engineer permission sets, including:

- centralized logs S3 read-only access;
- centralized logs KMS decrypt access.

### 3. Enable optional roles

After the required policies exist in the target account:

1. set `enable_secops_analyst` and/or `enable_secops_engineer` to `true` for the target account;
2. confirm the configured policy names exactly match the policies in that account;
3. re-plan and re-apply this stack.

The security-operations policy-name fields are optional and may remain `null` while its Analyst and Engineer roles are disabled.

---

## Inputs

### `identity_center_workloads`

Identity Center configuration keyed by workload environment.

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
- policy names must match customer-managed policies in the corresponding workload account before an attachment that uses them is enabled.

Example:

```hcl
identity_center_workloads = {
  dev = {
    account_id                     = "955775177042"
    primary_region                 = "us-east-1"
    enable_secops_analyst          = false
    enable_secops_engineer         = false
    logs_s3_readonly_policy_name   = "tf-secure-baseline-dev-CentralizedLogsS3ReadOnly"
    logs_cmk_decrypt_policy_name   = "tf-secure-baseline-dev-LogsKmsDecrypt"
  }

  staging = {
    account_id                     = "027326805885"
    primary_region                 = "us-east-1"
    enable_secops_analyst          = false
    enable_secops_engineer         = false
    logs_s3_readonly_policy_name   = "tf-secure-baseline-staging-CentralizedLogsS3ReadOnly"
    logs_cmk_decrypt_policy_name   = "tf-secure-baseline-staging-LogsKmsDecrypt"
  }

  prod = {
    account_id                     = "683620639956"
    primary_region                 = "us-east-1"
    enable_secops_analyst          = false
    enable_secops_engineer         = false
    logs_s3_readonly_policy_name   = "tf-secure-baseline-prod-CentralizedLogsS3ReadOnly"
    logs_cmk_decrypt_policy_name   = "tf-secure-baseline-prod-LogsKmsDecrypt"
  }
}
```

### `identity_center_secops`

Identity Center configuration for the security-operations account.

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
  account_id = "576735349008"
}
```

---

## GitHub Actions Variables

The control-plane Plan and Apply GitHub Environments provide these Terraform inputs as JSON:

| GitHub variable | Terraform variable |
|---|---|
| `IDENTITY_CENTER_WORKLOADS` | `TF_VAR_identity_center_workloads` |
| `IDENTITY_CENTER_SECOPS` | `TF_VAR_identity_center_secops` |

Store raw JSON in GitHub without surrounding shell quotes.

---

## Outputs

| Name | Description |
|---|---|
| `workload_permission_set_arns` | Permission-set ARN maps keyed by workload environment |
| `secops_permission_set_arns` | Permission-set ARNs for the security-operations account |

Example workload output shape:

```hcl
workload_permission_set_arns = {
  dev     = { /* enabled permission sets */ }
  staging = { /* enabled permission sets */ }
  prod    = { /* enabled permission sets */ }
}
```

---

## Important Notes

- Identity Center customer-managed policy attachments reference a policy by name and path in the target AWS account.
- A referenced policy must exist in the target account before AWS can provision the corresponding attachment successfully.
- IAM Identity Center provisions `AWSReservedSSO_*` roles into assigned target accounts.
- Disabling a role removes the Terraform-managed group, permission set, policy attachments, and account assignment associated with that role.
- Changes to map keys alter Terraform module instance addresses. Treat key renames as state migrations rather than ordinary configuration changes.
- The security-operations account intentionally does not receive the workload Operator role.