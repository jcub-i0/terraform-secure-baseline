# Security Dashboard

## Overview

The `security_dashboard` module creates a curated set of operational security views in AWS Security Hub using custom insights.

These insights provide a lightweight security-operations dashboard for reviewing active findings, prioritizing investigation, and monitoring workload security posture.

The module creates views for:

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

This view is intended for priority incident triage.

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

This insight is intentionally product-agnostic. An EC2 finding may originate from GuardDuty, Inspector, Security Hub controls, or another integrated product.

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

This provides a focused view of active failed Security Hub controls.

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

The explicit dependency ensures the workload security layer is established before Terraform creates the Security Hub insights.

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

These values identify the Terraform-managed insights. The module does not expose finding data or use these ARNs to trigger automation.

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

This module is read-only from an operational-response perspective: it creates Security Hub Insights but does not modify affected resources, publish notifications, or invoke responders.

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