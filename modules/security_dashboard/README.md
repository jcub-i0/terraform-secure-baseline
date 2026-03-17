# Security Dashboard

## Overview

The 'security_dashboard' module creates a curated set of operational security views within
AWS Security Hub using custom insights.

These insights act as a security operations dashboard, allowing analysts and operators to quickly
identify active security issues, prioritize response actions, and monitor overall security posture.

The dashboard surfaces key findings from integrated AWS security services including:

- GuardDuty
- Inspector
- Security Hub standards and controls
- EC2-related findings

This module does **not** create a standalone dashboard service. Instead, it defines Security Hub Insights that appear directly in the AWS Security Hub console.

After deployment, these insights are accessible in:

`AWS Console` ➔ `Security Hub` ➔ `Insights`

## Purpose

The goal of this module is to provide clear, actionable security visibility for the environment.

The insights created here enable security teams to quickly asnwer questions, such as:

- Are there any **high** or **critical** security findings?
- Are there any **active GuardDuty threats**?
- Are there any **vulnerabilities detected by Inspector**?
- Are there **security issues affecting EC2 instances**?
- Are there **failed compliance controls** in Security Hub?

These views support the operational security workflow used by this environmment.

---

# Insights Created

## High and Critical Findings

Displays all **active high and critical severity findings** across all integrated security services.

This insight is used for **priority incident triage**.

Grouped by:

`SeverityLabel`

---

## Active GuardDuty Findings

Displays all **active GuardDuty findings** detected within the environment.

This allows operators to quickly identify **potential threats or suspicious activity**.

Grouped by:

`SeverityLabel`

---

## Active Inspector Findings

Displays all **active Amazon Inspector findings**, including vulnerabilities detected on compute resources.

This provides visibility into the **vulnerability management posture** of the environment.

Grouped by:

`SeverityLabel`

---

## EC2 Findings

Displays all **active findings** associated with **EC2 instances**.

This insight helps identify security issues affecting compute workloads.

Grouped by:

`SeverityLabel`

Filtered by resource type:

`AwsEc2Instance`

---

## EC2 High and Critical Findings

Displays **high and critical severity findings** affecting **EC2 instances**.

This insight aligns directly with the environment’s automated incident response capabilities.

High and critical EC2 findings may trigger:

- EC2 isolation automation
- security alerts
- remediation workflows

Grouped by:

`ResourceId`

---

## Failed Controls


Displays **failed Security Hub compliance controls** across enabled frameworks.

This provides a quick view of **compliance posture** and highlights security configuration issues.

Grouped by:

`GeneratorId`

---

# Architecture Role

The security dashboard integrates with the broader security architecture:

`Security Services` ➔ `GuardDuty``Inspector``AWS Config``Security Hub Standards` ➔ `Security Hub Findings` ➔ `Security Hub Insights (Dashboard)` ➔ `Security Operations Visibility`

This module provides the visibility layer for the environment’s detection and response capabilities.

---

# Example Workflow

An example operational workflow using this dashboard:

1. GuardDuty detects suspicious activity
2. Finding appears in Security Hub
3. Finding is surfaced in the "Active GuardDuty Findings" insight
4. Security operators investigate
5. Automation or remediation may be triggered

Similarly:

`Inspector detects vulnerability` ➔ `Security Hub finding generated` ➔ `Appears in 'Active Inspector Findings'` ➔ `Operators prioritize patching or remediation`

---

# Deployment

This module is deployed as part of the root Terraform configuration.

Example usage:

```hcl
module "security_dashboard" {
  source = "./modules/security_dashboard"
}
```

---

# Outputs

`securityhub_insight_arns`

ARNs of the Security Hub insights created by this module.

Example output:

```json
{
  high_critical
  guardduty
  inspector
  ec2_findings
  ec2_high_critical
  failed_controls
}
```

These ARNs can be used for integrations or automation workflows.

---

# Requirements

The following services must already be enabled:

- AWS Security Hub
- Amazon GuardDuty
- Amazon Inspector

Security Hub msut be enabled in the same region where this module is deployed.

---

# Security Considerations

This module does not create or modify security controls directly. Instead, it provides operational visibility
into the security posture of the environment.

The insights defined here support:

- Security triage
- Vulnerability monitoring
- Threat detection
- Compliance monitoring

---

# Relationships to Other Modules

This module works alongside other components of the environment:

| Module | Function |
|--------|----------|
| `security` | Security Hub, GuardDuty, Inspector configuration |
| `automation` | Incident response Lambda functions |
| `monitoring` | SNS alerts and event routing |
| `patch_management` | OS patch compliance |

Together, these modules provide:

- `Detection`
- `Visibility`
- `Automation`
- `Remediation`

---

# Future Enhancements

Potential future improvements include:

- Additional insights for IAM-related findings
- Integration with centralized security reporting
- Cross-account Security Hub aggregation
- Automated reporting or alerting from insights

---

# Summary

The security_dashboard module provides a curated operational view of the environment’s security posture.

By defining Security Hub insights as code, the environment ensures:

- Consistent security visibility
- Repeatable deployments
- Infrastructure-as-Code managed dashboards
- Streamlined security operations