# Security Dashboard

## Overview

The `security_dashboard` module creates a curated set of operational security views in AWS Security Hub using custom insights.

The insights support investigation of findings already visible in Security Hub.
They do not generate findings, enable security services, validate Runtime
Monitoring coverage, or create alarms. `environment` changes the insight names;
none of the filters constrain findings by that environment, resource tag, or
baseline name prefix. Actual account/Region and finding-aggregation visibility
must be established separately from the display name.

All six insights are created unconditionally. Five exclude `RESOLVED` workflow
status; that is not the same as requiring `NEW` or excluding `SUPPRESSED`.
The Failed Controls insight does not filter workflow status at all. The exact
filters and groupings are implemented in [main.tf](main.tf):

- High and critical findings across integrated Security Hub products
- Active GuardDuty findings
- Active Inspector findings
- Active EC2 findings
- Active high and critical EC2 findings
- Failed Security Hub controls

This module does **not** create a standalone dashboard service and does not trigger remediation or containment actions. It defines Security Hub Insights that appear directly in the AWS Security Hub console.

After deployment, these insights are available under:

```text
AWS Console -> Security Hub -> Insights
```

## Purpose

The module provides consistent, Terraform-managed operational views that help security teams answer questions such as:

- Are there active **HIGH** or **CRITICAL** findings?
- Are there active GuardDuty findings?
- Are there active Inspector findings?
- Are there active findings affecting EC2 instances?
- Which active HIGH or CRITICAL findings affect EC2 instances?
- Are Security Hub controls currently failing?

The insights are visibility and triage aids. They do not replace the independent EventBridge, Lambda, monitoring, or centralized-security workflows that act on or route findings.

---

## Insights Created

### High and Critical Findings

Terraform resource:

```text
aws_securityhub_insight.high_critical
```

Displays findings that are:

- `SeverityLabel = HIGH` or `CRITICAL`
- `RecordState = ACTIVE`
- not in `WorkflowStatus = RESOLVED`

The insight spans integrated Security Hub products rather than being restricted to a single source.

Grouped by:

```text
SeverityLabel
```

This is a saved filter, not an adjudication that each result still requires
response. Findings marked SUPPRESSED can remain included because only RESOLVED
is excluded.

---

### Active GuardDuty Findings

Terraform resource:

```text
aws_securityhub_insight.guardduty_active
```

Displays findings that are:

- `ProductName = GuardDuty`
- `RecordState = ACTIVE`
- not in `WorkflowStatus = RESOLVED`

Grouped by:

```text
SeverityLabel
```

This view helps operators identify current GuardDuty threat-detection findings visible through Security Hub.

---

### Active Inspector Findings

Terraform resource:

```text
aws_securityhub_insight.inspector_active
```

Displays findings that are:

- `ProductName = Inspector`
- `RecordState = ACTIVE`
- not in `WorkflowStatus = RESOLVED`

Grouped by:

```text
SeverityLabel
```

This provides a focused view of active Inspector vulnerability findings imported into Security Hub.

---

### EC2 Findings

Terraform resource:

```text
aws_securityhub_insight.ec2_findings
```

Displays findings that are:

- associated with `AwsEc2Instance`
- `RecordState = ACTIVE`
- not in `WorkflowStatus = RESOLVED`

Grouped by:

```text
SeverityLabel
```

This filters resource type, not the compute instances owned by this baseline.
There is no environment-tag, VPC, instance-ID, or account-ID filter in the
insight itself.

---

### EC2 High and Critical Findings

Terraform resource:

```text
aws_securityhub_insight.ec2_high_critical
```

Displays findings that are:

- associated with `AwsEc2Instance`
- `SeverityLabel = HIGH` or `CRITICAL`
- `RecordState = ACTIVE`
- not in `WorkflowStatus = RESOLVED`

Grouped by:

```text
ResourceId
```

This insight is broader than the automatic EC2 isolation trigger.

The dashboard view does **not** restrict findings to GuardDuty and does **not** require `WorkflowStatus = NEW`. It therefore provides general EC2 triage visibility across integrated Security Hub products.

Automatic EC2 isolation is implemented separately in `modules/automation`. The isolation EventBridge rule is limited to active, `NEW`, HIGH/CRITICAL **GuardDuty** findings for `AwsEc2Instance` resources, and the Lambda then applies its configured automatic-isolation severity policy and runtime safety gates.

A finding appearing in this insight does not, by itself, mean that automatic isolation will occur.

---

### Failed Controls

Terraform resource:

```text
aws_securityhub_insight.failed_controls
```

Displays findings that are:

- `ProductName = Security Hub`
- `ComplianceStatus = FAILED`
- `RecordState = ACTIVE`

Grouped by:

```text
GeneratorId
```

This groups active failed Security Hub findings by `GeneratorId`; it is not a
control-evaluation history or a count of repeated failures over time. There is
no workflow-status condition here, so an ACTIVE finding with RESOLVED workflow
can still appear if its compliance status is FAILED.

---

## Architecture Role

The module provides a visibility layer over Security Hub findings.

Conceptually:

```text
GuardDuty / Inspector / Security Hub controls / other integrations
                            |
                            v
                   Security Hub Findings
                            |
                            v
                 Security Hub Insights
                            |
                            v
              Security Operations Visibility
```

The dashboard does not own the underlying detection, notification, or response mechanisms.

Those responsibilities remain separated:

```text
Detection / posture sources
        |
        +--> Security Hub insights for visibility
        |
        +--> EventBridge rules for routing
                |
                +--> Lambda automation
                |
                +--> SNS notification paths
```

---

## Example Operational Workflows

### GuardDuty investigation

Insight severity/resource filtering is not the automatic-isolation gate.
Do not infer `IsolationAllowed`, handler eligibility, or Operator authorization
from an insight result. See [automation](../automation/README.md).

```text
GuardDuty finding
    -> imported into Security Hub
    -> visible in Active GuardDuty Findings
    -> operator investigates
```

If the same finding independently satisfies the EC2-isolation EventBridge rule and Lambda safety gates, the automation workflow may also isolate the affected EC2 instance.

The insight itself does not trigger that automation.

### Inspector investigation

```text
Inspector finding
    -> imported into Security Hub
    -> visible in Active Inspector Findings
    -> operator prioritizes remediation
```

A HIGH or CRITICAL Inspector finding affecting EC2 can also appear in the EC2 High and Critical Findings insight. It is still not eligible for GuardDuty-only automatic EC2 isolation.

---

## Deployment

The sole input in [variables.tf](variables.tf) is required `environment` of type
`string`, without a default. This module inherits its AWS provider; it neither
selects a Region from the environment name nor verifies a target account.
The existing baseline call below supplies an environment label, not a finding
filter.

The baseline instantiates this module for each workload environment.

Current baseline integration:

```hcl
module "security_dashboard" {
  source = "../modules/security_dashboard"

  environment = var.environment

  depends_on = [
    module.security
  ]
}
```

The dependency orders locally managed resources, but it does not poll external
central-policy realization when local Security Hub account creation is disabled.
Confirm that the target account's hub is effective before applying insights;
changing the ownership mode is not a workaround for a pending central setup.

The reusable module itself has one input:

```hcl
variable "environment" {
  type = string
}
```

Standalone example:

```hcl
module "security_dashboard" {
  source = "./modules/security_dashboard"

  environment = "dev"
}
```

When using the module outside the baseline composition, the caller is responsible for ensuring Security Hub is available in the target account and Region before the insights are created.

---

## Outputs

### `securityhub_insight_arns`

The module exports the ARNs of all six custom insights:

```hcl
securityhub_insight_arns = {
  high_critical     = aws_securityhub_insight.high_critical.arn
  guardduty         = aws_securityhub_insight.guardduty_active.arn
  inspector         = aws_securityhub_insight.inspector_active.arn
  ec2_findings      = aws_securityhub_insight.ec2_findings.arn
  ec2_high_critical = aws_securityhub_insight.ec2_high_critical.arn
  failed_controls   = aws_securityhub_insight.failed_controls.arn
}
```

The output map contains exactly the six keys shown above. These are child-module
ARNs, not query results or proof that every insight is populated. The supplied
workload roots do not expose this map as a public output; do not assume a
root-level `terraform output securityhub_insight_arns` command exists.

---

## Requirements and Dependencies

### Security Hub

Security Hub must be enabled and available in the target account and Region for the custom insights to exist.

In the repository's centralized multi-account architecture, Security Hub CSPM governance may be managed from the dedicated `security-operations` account rather than locally in the workload account. The workload baseline still composes this dashboard after its workload security layer.

### GuardDuty and Inspector

GuardDuty and Inspector are **not direct Terraform dependencies** of this module.

The GuardDuty and Inspector insights filter Security Hub findings by `ProductName`. Those views become useful when the corresponding services are enabled and their findings are present in Security Hub.

Central GuardDuty organization governance is owned by the `security-operations` layer. Inspector remains workload-local when enabled by the effective workload configuration.

---

## Security Considerations

Creating/updating an insight changes the saved view configuration, not the
underlying resources or findings. Reading insight results is not remediation,
coverage validation, or proof that an empty view means a secure workload.

The insights support:

- Security triage
- Threat visibility
- Vulnerability monitoring
- EC2-focused investigation
- Compliance-control monitoring

The module should not be treated as an authorization or response-policy boundary. Response eligibility is enforced by the modules that own EventBridge routing, Lambda automation, IAM, and workload authorization controls.

---

## Relationships to Other Modules

| Module / layer | Relationship |
|---|---|
| `security` | Establishes workload-local security services and supporting Security Hub state according to the effective centralized/local ownership model. |
| `automation` | Owns incident-response and enrichment EventBridge/Lambda workflows, including the GuardDuty-scoped EC2 isolation path. |
| `monitoring` | Owns security notification routing and CloudWatch/SNS alerting paths. |
| `patch_management` | Provides host patch-management resources independently of Security Hub insights. |
| `bootstrap/security_operations/security_services` | Owns centralized Security Hub CSPM and GuardDuty organization governance in the five-account deployment model. |

The dashboard consumes the resulting Security Hub finding plane for visibility; it does not take ownership of those other controls.

---

## Ownership Boundary

The `security_dashboard` module owns:

- Six `aws_securityhub_insight` resources
- Per-environment insight naming
- Security Hub insight filters and grouping
- The `securityhub_insight_arns` output

It does **not** own:

- Security Hub account or organization enablement
- Security Hub CSPM standards or central configuration policies
- GuardDuty detectors or organization configuration
- Inspector enablement
- EventBridge rules
- Lambda responders
- SNS/SQS notification paths
- EC2 quarantine authorization
- EC2 isolation or rollback
- Finding workflow-state mutation
- Automated remediation

---

## Validation

The workload security validator checks service enablement and selected
relationships; it does not compare the six insight filters or test their
results. Inspect saved definitions and observations separately.

Run these local examples from the repository root with an initialized, applied
workload root and Bash, AWS CLI, Terraform, and `jq` available. Set a named
workload `AWS_PROFILE`, the intended service `AWS_REGION`, and an independently
known `EXPECTED_ACCOUNT_ID` first. `ENVIRONMENT` defaults to `dev`; select it
explicitly when inspecting another workload. The `${VAR:?message}` expressions
stop on missing values; their messages are not replacement placeholders.

These examples require a named local profile. That is not a requirement to add
`AWS_PROFILE` to GitHub OIDC jobs or other default-credential-chain executions.
The service Region is checked against applied Terraform output; it does not
change the independently configured state-backend Region.

```bash
set -euo pipefail
: "${AWS_PROFILE:?Set the local workload profile}"
: "${AWS_REGION:?Set the intended service Region}"
: "${EXPECTED_ACCOUNT_ID:?Set the independently known workload account ID}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
case "$ENVIRONMENT" in dev|staging|prod) ;; *) echo "Invalid workload" >&2; exit 1 ;; esac
[[ "$EXPECTED_ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || { echo "Invalid account ID" >&2; exit 1; }
export AWS_PROFILE AWS_REGION EXPECTED_ACCOUNT_ID
export AWS_DEFAULT_REGION="$AWS_REGION" AWS_PAGER=""

CALLER_ACCOUNT_ID="$(aws sts get-caller-identity \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" --query Account --output text)"
[[ "$CALLER_ACCOUNT_ID" == "$EXPECTED_ACCOUNT_ID" ]] || {
  echo "Unexpected AWS account; stopping" >&2; exit 1;
}
ACCOUNT_ID="$CALLER_ACCOUNT_ID"
ENV_DIR="environments/${ENVIRONMENT}"
OUTPUTS_JSON="$(terraform -chdir="$ENV_DIR" output -json)"
read_output_string() {
  jq -er --arg key "$1" '
    .[$key].value | if type == "string" and length > 0
    then . else error("Missing or invalid string output: " + $key) end
  ' <<< "$OUTPUTS_JSON"
}
APPLIED_REGION="$(read_output_string primary_region)"
[[ "$AWS_REGION" == "$APPLIED_REGION" ]] || {
  echo "Service Region differs from applied primary_region; stopping" >&2; exit 1;
}
NAME_PREFIX="$(read_output_string name_prefix)"
export NAME_PREFIX
```

This preflight confirms selected context, not every permission, resource, or
configuration. Do not treat a successful API read as proof of delivery or
operating effectiveness.

Read only the selected insight ARN from applied state; do not persist the full
state JSON, which can contain sensitive values:

```bash
INSIGHT_ARN="$(terraform -chdir="$ENV_DIR" show -json | jq -er '
  def modules: ., (.child_modules[]? | modules);
  [.values.root_module | modules | .resources[]? |
    select(.mode == "managed" and
      .address == "module.baseline.module.security_dashboard.aws_securityhub_insight.high_critical") |
    .values.arn] |
  if length == 1 and (.[0] | type == "string" and length > 0)
  then .[0] else error("Expected exact insight resource in applied state") end
')"
aws securityhub get-insights --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  --insight-arns "$INSIGHT_ARN" --output json
aws securityhub get-insight-results --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  --insight-arn "$INSIGHT_ARN" --output json
```

Check the exact returned ARN, name, `GroupByAttribute`, and complete filters.
Repeat for the other five resource addresses in `main.tf` when qualifying the
whole module. The one-resource example is not six-insight validation.

Results represent the service's returned view at inspection time, not a
historical completeness test. An empty result can reflect no matching findings,
wrong scope, inactive integrations, or other missing inputs. Confirm service
coverage and finding visibility before treating it as a favorable control
result. Retain timestamps and definitions alongside results; do not manufacture
live evidence from a configured insight.

---

## Future Enhancements

Potential future improvements include:

- Additional insights for IAM-related findings
- Additional service- or workload-specific triage views
- Insights aligned to newly introduced response workflows
- Automated reporting derived from insight or finding data
- Additional centralized security reporting integrations

Cross-account Security Hub governance and finding aggregation are already handled by the repository's centralized `security-operations` architecture and are therefore not listed as a future dashboard capability.

---

## Summary

The `security_dashboard` module provides a curated set of Terraform-managed Security Hub Insights for operational visibility.

Its role is intentionally narrow:

```text
Security Hub findings -> curated views -> operator visibility
```

It does not trigger containment or remediation. In particular, the broad EC2 HIGH/CRITICAL insight must not be confused with the stricter GuardDuty-only EC2 isolation workflow.

By keeping visibility separate from response policy, the baseline preserves clear ownership between Security Hub insights, centralized security governance, notification routing, and automated incident response.
