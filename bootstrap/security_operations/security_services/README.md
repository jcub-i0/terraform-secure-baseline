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

See [main.tf](main.tf), [variables.tf](variables.tf), [outputs.tf](outputs.tf), and [backend.tf](backend.tf). Implementation, declared rollout intent, live policy realization, and workload behavior are different evidence layers.

## Responsibilities

This stack currently manages:

- Security Hub CSPM in the `security-operations` account;
- the Security Hub finding aggregator for the current single-Region model;
- Security Hub CSPM central organization configuration;
- per-account Security Hub CSPM configuration policies and associations;
- GuardDuty configuration referencing an existing detector discovered through a data source (not detector creation or ownership);
- GuardDuty organization member enrollment and protection-plan configuration, retaining the Runtime Monitoring automated-agent contract;
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

The stack has `check` assertions for target account, enabled detector, unique association-account matches, and the required Workloads OU. **These are warning-producing assertions, not blocking account/OU preconditions.** Failed `check` assertions do not themselves prevent a Terraform Apply; see [Terraform check-block behavior](https://developer.hashicorp.com/terraform/language/block/check). Data-source/API failures or the separate resource preconditions can still block operations.

The account-ID format and `environment = security-operations` are variable validations. The provider Region postcondition must match `primary_region`. A CSPM policy resource has a blocking precondition requiring central organization configuration; each association has a blocking precondition requiring exactly one active name-matched account. There is no equivalent blocking target-account precondition or `allowed_account_ids` provider setting in this root. Check the expected caller independently before any Terraform operation and treat unresolved account warnings as a stop condition.

## Centralization Rollout Controls

Organization-wide behavior is opt-in.

| Variable | Default | Purpose |
| --- | ---: | --- |
| `enable_securityhub_organization_configuration` | `false` | Enables Security Hub CSPM central organization configuration. |
| `enable_guardduty_organization_configuration` | `false` | Enables GuardDuty organization enrollment and centrally managed protection plans. |
| `enable_securityhub_v2_organization_policy` | `false` | Creates and attaches the Security Hub V2 Organizations policy to the `Workloads` OU. |

This allows delegated administration and administrator-account resources to be
established before organization-wide governance is enabled.

All-flags-false is **not** a no-resource or no-prerequisite mode. CSPM administrator enablement, its `NO_REGIONS` aggregator, Security Hub V2 administrator enablement, Organization/root-OU discovery, and GuardDuty detector discovery remain unconditional. The detector must therefore be readable even with GuardDuty organization configuration disabled. A nonempty CSPM policy map with `create_policy=true` still attempts policy creation and requires the central-configuration flag.

These flags control Terraform resource materialization; they are not a reviewed decommissioning procedure. Turning them off after rollout can plan removal of central configuration or policy attachments. Disabling them also does not prove every previously enrolled member is disabled in AWS.

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

The frozen catalog resolves these keys (not an automatically updated standards catalog):

| Key | Standard/version selected by RC1 |
|---|---|
| `aws_fsbp` | AWS Foundational Security Best Practices `1.0.0` |
| `aws_tagging` | AWS Resource Tagging Standard `1.0.0` |
| `cis_1_2` | CIS AWS Foundations `1.2.0`, using its regionless ruleset ARN |
| `cis_5_0` | CIS AWS Foundations `5.0.0` |
| `nist_800_53` | NIST 800-53 `5.0.0` |
| `pci_dss` | PCI DSS `4.0.1` |

All other catalog entries construct commercial-partition ARNs from the resolved provider Region. This documents configured standard versions, not compliance certification or availability in every Region.

Policy-map keys are resolved against active AWS Organizations account names before associations are created. They are account **names**, not account IDs or OU names, and are not limited by Terraform to `dev`, `staging`, or `prod`.

Each map entry has this exact optional-field contract:

```hcl
securityhub_cspm_account_policies = {
  dev = {
    create_policy                = false
    associate_policy             = false
    enabled_standards            = ["aws_fsbp", "cis_5_0"]
    disabled_control_identifiers = []
  }
}
```

| Entry state | Materialized behavior |
|---|---|
| `create_policy=false`, `associate_policy=false` | No policy or association for that key |
| `create_policy=true`, `associate_policy=false` | Policy created; no target account lookup/association is required for that entry |
| Both `true` | Policy plus association to exactly one `ACTIVE` name-matched account |
| `create_policy=false`, `associate_policy=true` | Rejected by variable validation |

Created policies set `service_enabled=true`; there is no per-entry service-disable field. Unknown standard keys and blank map keys are rejected. The nonempty-standards validation is conditional on **association**, not merely policy creation. The module does not validate every control identifier's business meaning. A create-only empty-standard policy is not rejected by that particular variable check; provider/AWS acceptance remains separate.

The standard/control sets are sorted before resource construction. Renaming a policy-map key changes its `for_each` identity and can replace policy/association resources. Removing a key is not an innocuous rename.

## GuardDuty

The GuardDuty detector is discovered rather than created:

```hcl
data "aws_guardduty_detector" "main" {
  region = data.aws_region.current.region
}
```

The data source does not create, enable, import, or destroy the detector. It reads an existing detector; the code alone does not establish how that detector was originally created.

When `enable_guardduty_organization_configuration = true`, organization member auto-enrollment is set to:

```text
ALL
```

The default `guardduty_organization_features` input, when its rollout flag is enabled, materializes:

| Feature | Auto-enable |
| --- | --- |
| `S3_DATA_EVENTS` | `ALL` |
| `EBS_MALWARE_PROTECTION` | `ALL` |
| `LAMBDA_NETWORK_LOGS` | `ALL` |
| `RUNTIME_MONITORING` | `ALL` |

Runtime Monitoring additional configuration is:

| Configuration | Auto-enable |
| --- | --- |
| `ECS_FARGATE_AGENT_MANAGEMENT` | `ALL` |
| `EC2_AGENT_MANAGEMENT` | `ALL` |
| `EKS_ADDON_MANAGEMENT` | `NONE` |

The input represents `additional_configuration` as an ordered list of objects with `name` and `auto_enable`; preserve the configured order when reviewing provider diffs. Each feature's `auto_enable` defaults to `ALL` and its additional list to `[]` when omitted within a supplied entry. Supplying a new top-level map replaces the default map; it is not automatically merged with the four default features.

Feature and additional-configuration auto-enable values are validated against `ALL`, `NEW`, and `NONE`. Additional names are restricted to the three names shown above. The input validation does not impose a closed set of top-level feature names or reject every duplicate/invalid parent-child combination; provider/AWS validation and the live validator remain separate.

Member auto-enrollment is fixed at `ALL` when enabled, even if a caller selects `NEW` or `NONE` for a particular protection feature. The feature map is not an assertion that every account's realized runtime coverage is healthy.

The frozen validator is stricter than the variable schema: when GuardDuty organization configuration is enabled, it requires `RUNTIME_MONITORING=ALL` with exactly `EC2_AGENT_MANAGEMENT=ALL`, `ECS_FARGATE_AGENT_MANAGEMENT=ALL`, and `EKS_ADDON_MANAGEMENT=NONE`. That is a required validation contract, not merely an optional default. A custom map accepted by Terraform's input validation can fail this baseline check. Other managed features are compared against resource-backed state/output values, and unmanaged live enabled features are rejected.

This stack owns the organization-wide secure default. Workload Terraform does **not** manage these organization features. Instead, each workload ECS cluster expresses its own deployment-profile-derived participation intent with `GuardDutyManaged=true` for `production`/`development` or `GuardDutyManaged=false` for `minimal`.

For Fargate, GuardDuty service-manages runtime-agent injection and telemetry after the central policy, workload cluster intent, IAM, and networking prerequisites are present. Workload Terraform retains ownership of the ECS cluster, task execution IAM, and the Terraform-owned `guardduty-data` endpoint.

## Security Hub V2

Security Hub V2 is enabled directly in the `security-operations` account.

When `enable_securityhub_v2_organization_policy = true`, this stack creates an
AWS Organizations policy of type:

```text
SECURITYHUB_POLICY
```

The policy enables Security Hub V2 in `primary_region` and is attached to the
root-level `Workloads` OU. The exact content uses `enable_in_regions.@@assign = [<resolved provider Region>]` and `disable_in_regions.@@assign = []`; it does not request blanket disablement in all other Regions. The target OU lookup is the literal root-level name `Workloads`, not a root input.

The attachment establishes configured inheritance for descendant accounts. Validate effective policy separately; there is no V2 finding aggregator or cross-Region recovery orchestration in this root.

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

The complete nine-output interface is:

| Output | Meaning |
|---|---|
| `security_operations_account_id` | Actual caller account from `aws_caller_identity`, not an independent assertion that it equals the configured `account_id` |
| `securityhub_home_region` | Resolved provider Region |
| `central_security_features_enabled` | Input booleans with keys `securityhub_cspm`, `guardduty`, `securityhub_v2`; not overall enablement/health of all unconditional resources |
| `securityhub_finding_aggregator_arn` | Resource-backed CSPM aggregator ARN |
| `securityhub_cspm_configuration_policy_ids` | Map of created policy IDs keyed by configured account name; `{}` when none |
| `securityhub_cspm_policy_association_target_ids` | Map of created associations' target account IDs; `{}` when none |
| `guardduty_detector_id` | Discovered existing detector ID |
| `guardduty_organization_features` | Resource-backed feature values and additional-configuration lists; `{}` when feature resources are not managed |
| `securityhub_v2_organization_policy_id` | Policy ID or `null` when its resource is absent |

Validation still queries AWS to verify selected live configuration. In particular, a caller-account output matching its own live read is not a substitute for independently supplying the intended `EXPECTED_ACCOUNT_ID`.

## Backend

State is stored in the dedicated security-operations S3 backend:

```text
bucket: tf-secure-baseline-security-operations-state
key:    security-operation/security-services.tfstate
region: us-east-1
```

Native S3 state locking is enabled with `use_lockfile = true`. The singular `security-operation/` spelling above is the actual frozen key. Do not “correct” it to `security-operations/` in an existing deployment without a deliberate state migration.

[providers.tf](providers.tf) pins Terraform `1.15.8` and AWS provider `6.66.0` and explicitly selects `var.primary_region`. Keep service `AWS_REGION`, `AWS_DEFAULT_REGION`, and the Terraform input aligned. `state_region` belongs to the sibling state root; neither it nor `primary_region` rewrites this backend's literal Region/key. Use the [state procedures](../state/README.md) when bootstrapping or intentionally migrating.

## Deployment

The local execution context must be selected **before backend initialization**, not only for the plan/apply commands. Adopt/import already-existing managed resources deliberately; do not issue an unreviewed second enablement against resources owned outside this state.

Run from the repository root in a local named-profile session. Set the following values deliberately; `<...>` values are placeholders, not deployment defaults. The `${VAR:?message}` expressions below reject unset or empty variables. They do not establish that a supplied value is correct.

```bash
export AWS_PROFILE="security-operations"
export AWS_REGION="<security-services-region>"
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
  root="bootstrap/security_operations/security_services"
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

Set `primary_region` to the same selected service Region and `account_id` to the independently expected account in the reviewed local input file. The shell account preflight does not automatically compare those file values; inspect them and the plan's check results before acceptance.

The standalone Terraform Plan target `security-operations-security-services` uses `security-operations-plan`; its plan is informational. The generic workload Apply/Destroy workflows do not provide a central security-services Apply/teardown path. A controlled administrative Apply is a separate approved operation, not the next automatic step of evidence export.

Apply the control-plane Organizations stack first whenever delegated
administration, trusted access, Security Hub V2 policy prerequisites, or other
management-account dependencies change.

After applying this stack, validate the effective organization configuration
before accepting the central rollout. Workload Config and other local prerequisites can be required for standards realization; initial policy creation/association and final workload acceptance are distinct stages.

There is no `production_retirement_mode` input or blanket `prevent_destroy` guard for these service resources. Retiring one workload does not authorize disabling central governance for the others. Coordinate policy/association removal with the management-account prerequisites and retained accounts; turning a feature flag off is not a complete service decommissioning runbook.

## Validation

Centralized security validation verifies live AWS state rather than relying only
on Terraform state.

Run from the repository root against the initialized/applied security-services state. The direct validator compares the live caller with the caller-account output recorded in state; it does **not** consume `EXPECTED_ACCOUNT_ID`. The exporter performs that independent expected-account check. For a direct run, the local preflight below supplies it explicitly before invoking the validator:

```bash
(
  set -euo pipefail
  export AWS_PROFILE="${AWS_PROFILE:?Set the security-operations profile}"
  export AWS_REGION="${AWS_REGION:?Set the security-services Region}"
  export AWS_DEFAULT_REGION="$AWS_REGION"
  : "${EXPECTED_ACCOUNT_ID:?Set the intended security account ID}"
  [[ "$EXPECTED_ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || {
    echo "Expected account ID must contain exactly 12 digits" >&2; exit 1;
  }
  actual_account="$(aws sts get-caller-identity --query Account --output text)"
  [[ "$actual_account" == "$EXPECTED_ACCOUNT_ID" ]] || {
    echo "AWS account mismatch; validator not started" >&2; exit 1;
  }
  ./scripts/validation/validate-security-operations.sh
)
```

The validator checks:

- the live account against the state-recorded caller account, and service Region against the state-recorded home Region;
- required AWS Organizations trusted-service and delegated-administrator state;
- Security Hub CSPM administrator state and finding aggregation;
- Security Hub CSPM CENTRAL organization configuration;
- CSPM configuration policies and workload associations;
- the GuardDuty administrator detector, organization enrollment, protection plans, and Runtime Monitoring configuration;
- the fixed Runtime Monitoring baseline contract above, followed by equality of the Terraform-managed GuardDuty feature subset against live AWS;
- that any additional GuardDuty organization features returned by AWS outside the Terraform-managed set remain disabled (`NONE`), including any additional configurations;
- Security Hub V2 administrator state;
- the `SECURITYHUB_POLICY` attachment to the `Workloads` OU; and
- effective Security Hub V2 policy for configured workload accounts.

The distinction between the Terraform-managed subset and AWS's full returned feature inventory is intentional. AWS can return supported organization features that this stack does not manage. The validator does not require those disabled features to disappear from the API response; it requires them to remain disabled and fails closed if any unmanaged feature becomes enabled.

Full AWS Organizations topology and workload-account placement are validated
separately by the control-plane validation layer. Workload-local realization of
centrally governed services is validated by the workload baseline layer.

Evidence can be exported with:

```bash
AWS_PROFILE="${AWS_PROFILE:?Set the security-operations profile}" \
AWS_REGION="${AWS_REGION:?Set the security-services Region}" \
EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:?Set the intended security account ID}" \
./scripts/validation/export-security-operations.sh
```

Generated evidence is written beneath:

```text
validation-results/security-operations/security-services/<timestamp>/
```

The exporter reruns this layer's validator and writes the generated summary/log package. It does not validate the security-operations state/account roots as a separate bootstrap layer or prove actual Fargate agents, backup restores, response delivery, or human access. The normal workload suite remains sixteen validators; this layer does not add a seventeenth.

The validator also requires the `securityhub_v2_organization_policy_id` output key before its feature-specific branches. With the V2 policy disabled, that root output evaluates to `null`; an absent key fails the required-output gate. Do not promise that every Terraform-valid staged/all-flags-false configuration passes the final centralized-security validator. The source defines rollout stages, but the complete validation path has additional requirements.

An enabled contract and a disabled rollout path exercise different checks. Review the exact feature flags, warnings, live associations and effective-policy results rather than describing every green run as a complete central rollout. See the [script reference](../../../scripts/validation/README.md) and [evidence guide](../../../docs/assurance/validation-evidence-guide.md) for per-run provenance and limitations. No source edit or documentation update establishes a new live qualification at RC1.
