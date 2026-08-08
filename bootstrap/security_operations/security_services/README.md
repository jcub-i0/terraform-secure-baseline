# Security Operations Security Services

This Terraform root configures centralized AWS security-service administration
from the dedicated `security-operations` account.

It is intentionally separate from the AWS Organizations management-account
stack. The control-plane Organizations stack establishes organization-level
prerequisites such as trusted service access, delegated-administrator
registration, the Security Hub V2 policy type, and management-account
service-linked/delegation resources. This stack owns the delegated
administrator-side Security Hub CSPM, GuardDuty, and Security Hub V2
configuration.

## Responsibilities

This stack currently manages:

- Security Hub CSPM in the `security-operations` account;
- the Security Hub finding aggregator for the current single-Region model;
- Security Hub CSPM central organization configuration;
- per-account Security Hub CSPM configuration policies and associations;
- the existing GuardDuty delegated-administrator detector by discovery;
- GuardDuty organization member enrollment and protection-plan configuration;
- Security Hub V2 enablement in the `security-operations` account; and
- the Security Hub V2 AWS Organizations policy attached to the root-level
  `Workloads` OU.

It does **not** own:

- AWS Organizations creation or OU creation;
- trusted service access;
- Security Hub or GuardDuty delegated-administrator registration;
- management-account Security Hub V2 prerequisites;
- workload-local remediation, EventBridge rules, or Lambda response logic; or
- workload-local Security Hub CSPM, GuardDuty, or Security Hub V2 resources
  when centralized ownership is enabled.

Those boundaries are intentional so management-account governance,
administrator-side security services, and workload-local response remain
separate Terraform ownership domains.

## Prerequisites

Before applying this stack:

1. The `security-operations` account must exist and be a member of the AWS
   Organization.
2. The control-plane Organizations stack must have established the required
   delegated-administrator and trusted-access prerequisites.
3. GuardDuty must already be enabled for the `security-operations` delegated
   administrator in the configured Region.
4. If Security Hub V2 organization policy management is enabled, exactly one
   root-level OU named `Workloads` must exist.
5. Any workload account named in `securityhub_cspm_account_policies` and marked
   for association must exist as exactly one active AWS Organizations account.

The stack also checks that the active AWS credentials belong to the configured
`account_id`.

## Centralization Rollout Controls

Organization-wide behavior is opt-in.

| Variable | Default | Purpose |
| --- | ---: | --- |
| `enable_securityhub_organization_configuration` | `false` | Enables Security Hub CSPM central organization configuration. |
| `enable_guardduty_organization_configuration` | `false` | Enables GuardDuty organization enrollment and centrally managed protection plans. |
| `enable_securityhub_v2_organization_policy` | `false` | Creates and attaches the Security Hub V2 Organizations policy to the `Workloads` OU. |

This allows delegated administration and administrator-account resources to be
established before organization-wide governance is enabled.

For the centralized project deployment, these controls are expected to be
enabled after the corresponding management-account prerequisites have been
applied.

## Security Hub CSPM

Security Hub CSPM is enabled in the `security-operations` account with default
standards and automatic control enablement disabled:

```hcl
enable_default_standards = false
auto_enable_controls     = false
```

The finding aggregator uses:

```hcl
linking_mode = "NO_REGIONS"
```

which matches the current single-Region architecture.

When `enable_securityhub_organization_configuration = true`, the stack enables
central organization configuration with:

```text
configuration_type      = CENTRAL
auto_enable             = false
auto_enable_standards   = NONE
```

Workload configuration is controlled through
`securityhub_cspm_account_policies`.

Example:

```hcl
securityhub_cspm_account_policies = {
  dev = {
    create_policy    = true
    associate_policy = true

    enabled_standards = [
      "aws_fsbp",
      "cis_5_0",
    ]

    disabled_control_identifiers = []
  }
}
```

Supported standard keys are:

- `aws_fsbp`
- `aws_tagging`
- `cis_1_2`
- `cis_5_0`
- `nist_800_53`
- `pci_dss`

Policy-map keys are resolved against active AWS Organizations account names
before associations are created.

## GuardDuty

The GuardDuty detector is discovered rather than created:

```hcl
data "aws_guardduty_detector" "main"
```

This preserves the detector created when the account became the GuardDuty
delegated administrator.

When `enable_guardduty_organization_configuration = true`, organization member
auto-enrollment is set to:

```text
ALL
```

The default centrally managed protection plans are:

| Feature | Auto-enable |
| --- | --- |
| S3 data events | `ALL` |
| EBS malware protection | `ALL` |
| Lambda network logs | `ALL` |
| Runtime Monitoring | `ALL` |

Runtime Monitoring additional configuration defaults to:

| Configuration | Auto-enable |
| --- | --- |
| `EC2_AGENT_MANAGEMENT` | `ALL` |
| `ECS_FARGATE_AGENT_MANAGEMENT` | `NONE` |
| `EKS_ADDON_MANAGEMENT` | `NONE` |

The additional configuration is modeled as an ordered list to match the AWS
provider's ordered GuardDuty configuration behavior.

## Security Hub V2

Security Hub V2 is enabled directly in the `security-operations` account.

When `enable_securityhub_v2_organization_policy = true`, this stack creates an
AWS Organizations policy of type:

```text
SECURITYHUB_POLICY
```

The policy enables Security Hub V2 in `primary_region` and is attached to the
root-level `Workloads` OU. Workload accounts beneath that OU inherit the
organization policy.

Workload Terraform should use:

```hcl
manage_securityhub_v2_locally = false
```

when the account is governed by this centralized policy.

Management-account prerequisites for `SECURITYHUB_POLICY` are owned by
`bootstrap/control_plane/organizations` and are intentionally not duplicated
here.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `cloud_name` | `string` | required | Cloud/platform name used for naming. |
| `environment` | `string` | required | Must be `security-operations`. |
| `primary_region` | `string` | required | Primary Region and Security Hub home Region. |
| `account_id` | `string` | required | 12-digit security-operations AWS account ID. |
| `enable_securityhub_organization_configuration` | `bool` | `false` | Enables central Security Hub CSPM organization configuration. |
| `securityhub_cspm_account_policies` | `map(object)` | `{}` | Per-account CSPM policy and association configuration. |
| `enable_guardduty_organization_configuration` | `bool` | `false` | Enables GuardDuty organization configuration. |
| `guardduty_organization_features` | `map(object)` | see `variables.tf` | GuardDuty organization protection-plan configuration. |
| `enable_securityhub_v2_organization_policy` | `bool` | `false` | Enables the workload Security Hub V2 Organizations policy. |

See `variables.tf` for the complete object schemas and validation rules.

## Outputs

The stack exposes a deliberately small set of identifiers and expected
configuration values for downstream validation and evidence tooling:

- `security_operations_account_id`
- `securityhub_home_region`
- `central_security_features_enabled`
- `securityhub_finding_aggregator_arn`
- `securityhub_cspm_configuration_policy_ids`
- `securityhub_cspm_policy_association_target_ids`
- `guardduty_detector_id`
- `securityhub_v2_organization_policy_id`

These outputs describe Terraform intent and stable resource identifiers.
Validation scripts should still query AWS directly to verify effective live
configuration.

## Backend

State is stored in the dedicated security-operations S3 backend:

```text
bucket: tf-secure-baseline-security-operations-state
key:    security-operation/security-services.tfstate
region: us-east-1
```

Native S3 state locking is enabled with `use_lockfile = true`.

## Deployment

From this directory:

```bash
terraform init
terraform fmt -check
terraform validate
AWS_PROFILE=security-operations terraform plan
AWS_PROFILE=security-operations terraform apply
```

Apply the control-plane Organizations stack first whenever delegated
administration, trusted access, Security Hub V2 policy prerequisites, or other
management-account dependencies change.

After applying this stack, validate the effective organization configuration
before deploying or reconciling workload environments.

## Validation

Centralized security validation should verify live AWS state rather than rely
only on Terraform state. The planned `validate-security-operations.sh` workflow
should cover, at minimum:

- the expected security-operations account and Region;
- Security Hub delegated administration and central configuration;
- CSPM configuration-policy associations;
- GuardDuty detector status, organization enrollment, and protection plans;
- Security Hub V2 administrator enablement;
- the `SECURITYHUB_POLICY` attachment and effective workload policy; and
- expected workload account placement beneath the `Workloads` OU.

Terraform outputs from this stack provide expected identifiers; AWS API
responses provide the effective-state validation evidence.