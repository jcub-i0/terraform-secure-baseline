# Adoption Guide - tf-secure-baseline

## Purpose

This guide helps teams determine when and how to adopt `tf-secure-baseline`.

It explains:

- Who this baseline is designed for
- What problems it helps solve
- What maturity level it assumes
- How teams should customize it
- What should be completed before production use
- What this baseline does and does not provide

For deployment instructions, see:

```text
docs/quickstart.md
```

For architecture details, see:

```text
docs/architecture-overview.md
```

---

## Intended Audience

`tf-secure-baseline` is designed for teams that need a secure AWS foundation without building every control from scratch.

It is especially useful for:

- SaaS companies handling customer PII
- Startups preparing for SOC 2 or ISO 27001
- Small and mid-sized engineering teams
- Cloud security teams building reusable AWS patterns
- Platform teams standardizing environment deployments
- Consultants implementing secure AWS foundations for clients

The baseline is opinionated, but it is intended to be adaptable.

---

## When to Use This Baseline

Use this baseline when your AWS environment needs:

- Multi-account environment separation
- Private-by-default infrastructure
- Centralized logging
- Continuous monitoring
- IAM Identity Center-based human access
- GitHub OIDC-based CI/CD access
- Security Hub and GuardDuty visibility
- AWS Config posture monitoring
- Event-driven incident response
- Automated EC2 isolation
- Controlled rollback workflows
- IP threat enrichment
- Tamper detection
- Break-glass monitoring
- Backup and patch management foundations

This project is most appropriate when the environment is expected to host persistent workloads that handle sensitive data or support production-like systems.

---

## Target Use Cases

### SaaS Application Environments

This baseline is well suited for SaaS applications that process or store sensitive customer data.

Examples:

- Customer portals
- Internal admin applications
- APIs handling PII
- Data processing services
- Tenant-facing workloads
- Backend services supporting regulated workflows

---

### SOC 2 / ISO 27001 Readiness

This baseline can support evidence collection and technical control implementation for areas such as:

- Access control
- Logging and monitoring
- Change management
- Encryption
- Incident response
- Vulnerability management
- Backup and recovery
- Infrastructure security

It does **not** guarantee compliance or certification by itself.

Policies, procedures, human review, vendor management, risk management, and audit evidence are still required.

---

### Consulting and Client Deployments

This baseline can be used as a reusable implementation foundation for client environments.

It provides a repeatable structure for:

- Account separation
- Terraform state management
- GitHub OIDC setup
- Centralized identity
- Logging
- Detection
- Response automation

Consultants can adapt the modules, naming conventions, email targets, regions, and enabled services to match client requirements.

---

## Problems This Helps Solve

This baseline helps address common AWS security and operational problems, including:

- Workloads deployed with public IPs by default
- Flat single-account AWS environments
- Lack of environment separation
- Long-lived CI/CD access keys
- Weak or inconsistent logging
- No centralized detection layer
- Missing Security Hub / GuardDuty / Config coverage
- Limited incident containment capability
- Manual and inconsistent incident response
- Lack of tamper detection
- No controlled rollback workflow
- Poor visibility into break-glass access
- Unclear Terraform state ownership
- Terraform stacks destroying their own execution roles
- IAM policy delete conflicts caused by unmanaged dependencies

---

## What This Baseline Provides

Deploying this baseline provides a production-aligned AWS security foundation with:

- Multi-account architecture
- Control-plane separation
- Environment-specific Terraform state
- GitHub OIDC CI/CD roles
- IAM Identity Center groups and permission sets
- Private VPC networking
- AWS Network Firewall egress inspection
- VPC endpoints
- Centralized logging
- KMS-backed encryption
- CloudTrail
- AWS Config
- GuardDuty
- Security Hub
- Inspector
- EventBridge rules
- SNS alerts
- EC2 isolation automation
- EC2 rollback workflow
- IP enrichment workflow
- Tamper detection
- Break-glass monitoring
- AWS Backup
- SSM Patch Manager

---

## What This Baseline Does Not Provide

This baseline is not a complete security program by itself.

It does **not** provide:

- Guaranteed SOC 2 or ISO 27001 certification
- 24/7 SOC monitoring
- Managed incident response
- Full enterprise landing zone functionality
- Account vending automation
- Complete SCP strategy
- Application-layer zero trust
- Service mesh
- Full SIEM integration
- Threat hunting operations
- Secure SDLC process
- Application vulnerability scanning
- Vendor risk management
- Business continuity planning
- Human policy enforcement

It provides technical cloud security foundations that should be paired with organizational controls and operational processes.

---

## Baseline, Not One-Size-Fits-All

`tf-secure-baseline` is intended to be a **secure starting point**, not a universal product that fits every organization without changes.

It provides opinionated defaults for common SaaS security needs, but every organization should review and adapt the baseline based on:

- Application architecture
- Data sensitivity
- Compliance requirements
- Network requirements
- Existing identity model
- CI/CD tooling
- Budget constraints
- Operational maturity

The goal is to provide a strong foundation that teams can safely extend, not to replace environment-specific design decisions.

---

## Adoption Maturity

### Good Fit

This baseline is a good fit if your team:

- Has or plans to have multiple AWS accounts
- Uses Terraform or wants to standardize on Terraform
- Uses GitHub Actions or wants OIDC-based CI/CD
- Needs secure defaults for AWS infrastructure
- Wants centralized access through IAM Identity Center
- Needs better logging, detection, and response
- Is preparing for audit or customer security review
- Has at least one engineer comfortable operating AWS and Terraform

---

### Possible Fit with Customization

This baseline may still work, but will require more customization if your team:

- Uses GitLab, Azure DevOps, or another CI/CD system
- Uses a different identity provider model
- Needs different region or naming conventions
- Already has a central networking account
- Already has a SIEM/logging pipeline
- Requires multi-region failover
- Uses containers or Kubernetes as the primary workload platform
- Needs organization-wide GuardDuty or Security Hub delegation

---

### Poor Fit

This baseline may not be appropriate if your environment is:

- Fully air-gapped
- Extremely short-lived or experimental
- Not intended to host persistent workloads
- Already managed by a mature enterprise landing zone
- Required to follow a very different internal cloud operating model
- Optimized primarily for lowest possible AWS cost
- Designed for hyperscale workloads out of the box

---

## Recommended Adoption Path

Adopt the baseline in stages.

Do not attempt to customize everything before the first successful deployment.

---

## Phase 1 - Review Architecture

Start by reviewing:

```text
docs/architecture-overview.md
docs/design-principles.md
docs/quickstart.md
```

Confirm that the model aligns with your intended AWS account strategy.

Key decisions:

- Will you use `dev`, `staging`, and `prod` accounts?
- Will you use a separate `control-plane` account?
- Will GitHub Actions manage Terraform?
- Will IAM Identity Center be used for human access?
- Which AWS region will be primary?
- Who receives security notifications?

---

## Phase 2 - Prepare AWS Accounts

Create or identify the required AWS accounts:

```text
control-plane
dev
staging
prod
```

The control-plane account should manage:

- AWS Organizations
- IAM Identity Center
- Control-plane Terraform state
- Control-plane GitHub OIDC roles

Workload accounts should host:

- Dev baseline and GitHub OIDC resources
- Staging baseline and GitHub OIDC resources
- Prod baseline and GitHub OIDC resources

---

## Phase 3 - Deploy the Baseline

Follow:

```text
docs/quickstart.md
```

Recommended deployment order:

```text
1. bootstrap/control_plane/state
2. bootstrap/control_plane/account
3. bootstrap/control_plane/organizations
4. bootstrap/<env>/state
5. bootstrap/<env>/account
6. environments/<env>
7. bootstrap/control_plane/identity_center
8. validation tests
```

Deploy `dev` first before deploying `staging` or `prod`.

---

## Phase 4 - Validate Controls

After deployment, review:

```text
docs/validation-checklist.md
```

Then run the Lambda workflow tests located at:

```text
docs/lambda_tests/ec2_isolation.md
docs/lambda_tests/ec2_rollback.md
docs/lambda_tests/ip_enrichment.md
```

Do not consider the environment production-ready until validation completes successfully.

---

## Phase 5 - Customize for Your Organization

After a successful deployment, customize the baseline for your environment.

Common customization areas include:

- Naming conventions
- AWS regions
- CIDR ranges
- Number of Availability Zones
- SecOps email recipients
- GitHub organization and repository names
- IAM Identity Center groups
- Permission set behavior
- Enabled Security Hub standards
- AWS Config rules
- VPC endpoint coverage
- Backup retention
- Patch windows
- Tags
- KMS key aliases and policies
- Network Firewall rules
- Lambda alert formatting

---

## Phase 6 - Production Readiness Review

Before using the baseline for production workloads, review:

- Terraform state protection
- GitHub environment protections
- Required reviewers for prod apply workflows
- IAM Identity Center assignments
- Break-glass access procedure
- SNS subscription confirmation
- CloudTrail logging status
- GuardDuty / Security Hub / Config status
- Backup policies
- Patch management settings
- Cost estimates
- Destruction/cleanup procedure
- Incident response runbooks

---

## Configuration Decisions

Before adopting this baseline, answer the following questions:

### Account Strategy

- Will each environment use a separate AWS account?
- Which account is the AWS Organizations management account?
- Will the control-plane account be separate from workload accounts?
- Who owns each account?

---

### Region Strategy

- What is the primary AWS region?
- Are additional regions required?
- Should CloudTrail be multi-region?
- Are disaster recovery requirements regional or multi-region?

---

### Identity Strategy

- Who administers IAM Identity Center?
- Which users need `SecOps-Operator` access?
- Will `SecOps-Analyst` and `SecOps-Engineer` roles be enabled?
- Who owns break-glass credentials?
- How is break-glass access reviewed?

---

### CI/CD Strategy

- Will GitHub Actions manage Terraform?
- Which GitHub environments are required?
- Who can approve production applies?
- Should plan and apply roles be separated?
- Are GitHub environment protections enabled?
- Are static AWS keys prohibited for CI/CD?

---

### Network Strategy

- What VPC CIDR ranges will be used?
- How many Availability Zones are required?
- What outbound internet access is required?
- Is AWS Network Firewall required in all environments?
- Which VPC endpoints are required?
- Are any workloads expected to be publicly reachable?

---

### Logging and Monitoring Strategy

- Who receives SecOps alerts?
- Who receives compliance alerts?
- How long should logs be retained?
- Should Object Lock be enabled?
- What Security Hub standards should be enabled?
- What AWS Config rules are required?
- Should findings be exported to an external SIEM?

---

### Incident Response Strategy

- Who reviews EC2 isolation events?
- Who is allowed to trigger rollback?
- What ticketing or approval system is used?
- How should SNS alerts be routed?
- Who reviews break-glass role usage?
- What is the escalation path for tamper alerts?

---

### Backup and Patch Strategy

- Which resources should be backed up?
- What retention periods are required?
- What patch windows are acceptable?
- Who reviews patch compliance?
- What recovery testing is required?

---

## Operational Considerations

### Terraform State

Terraform state is sensitive and must be protected.

State buckets are automatically deployed with:

- Encryption
- Versioning
- Restricted access
- Locking
- Controlled bucket administration

The `state` substacks are applied locally first and should be handled carefully. After initial deployment, the local states can (and should) be moved to a more secure remote location.

---

### GitHub OIDC Roles

GitHub OIDC roles are critical CI/CD access components.

The `account` substacks should be modified carefully.

Do not destroy account stacks before destroying the baseline stacks they manage.

The `control-plane` account stack should generally be treated as manual/local-only because it creates the roles GitHub uses to access the control plane.

---

### IAM Identity Center

Identity Center access is centralized from the control plane.

Some optional Identity Center permissions depend on IAM policies created by workload baselines.

This is expected.

The intended pattern is:

```text
1. Deploy minimal Identity Center roles
2. Deploy workload baseline
3. Pass baseline-created IAM policy names into Identity Center
4. Re-apply Identity Center
```

---

### Destroy Order

Destroy order matters.

Incorrect destroy order can cause:

- IAM policy delete conflicts
- Broken GitHub Actions access
- Orphaned resources
- State backend deletion before dependent stacks are gone

Before teardown, follow the destruction procedure in:

```text
docs/quickstart.md
```

---

## Cost Considerations

This baseline prioritizes security and visibility.

Some services can create meaningful cost, especially when deployed across `dev`, `staging`, and `prod`.

Common cost drivers include:

- AWS Network Firewall
- NAT Gateway
- VPC endpoints
- CloudWatch Logs
- VPC Flow Logs
- GuardDuty
- Security Hub
- Inspector
- KMS requests
- Backup storage
- EC2 instances
- RDS instances, if enabled

Teams should review cost expectations before deploying all environments.

Recommended adoption pattern:

- Deploy and validate `dev` first
- Review cost
- Deploy `staging`
- Review cost again
- Deploy `prod`

Future versions may support deployment profiles such as:

```text
network_firewall
nat_only
vpc_endpoints_only
```

---

## Security Review Checklist Before Production Use

Before using this baseline for production workloads, confirm:

- Required AWS accounts exist and are controlled.
- Terraform state resources are protected.
- GitHub OIDC roles are working.
- GitHub environments have appropriate protections.
- IAM Identity Center groups are assigned correctly.
- Break-glass access is documented and tested.
- CloudTrail is logging.
- GuardDuty is enabled.
- Security Hub is enabled.
- AWS Config is recording.
- SNS subscriptions are confirmed.
- EC2 isolation and rollback tests pass.
- IP enrichment tests pass.
- Backup resources are configured.
- Patch management settings are reviewed.
- Cost estimates are understood.
- Destroy procedure is understood.

---

## How to Extend the Baseline

Common extension areas include:

- Adding Service Control Policies
- Adding delegated GuardDuty administration
- Adding delegated Security Hub administration
- Adding external SIEM forwarding
- Adding additional AWS Config rules
- Adding additional Lambda responders
- Adding support for alternative CI/CD providers
- Adding cost-optimized egress modes
- Adding more granular Identity Center roles
- Adding container or Kubernetes workload patterns
- Adding multi-region disaster recovery patterns

Extensions should preserve the core design principles:

- Keep control-plane resources separate
- Keep state isolated
- Avoid circular dependencies
- Prefer least privilege
- Preserve logging and detection integrity
- Avoid introducing long-lived CI/CD credentials

---

## Summary

`tf-secure-baseline` is appropriate for teams that need a secure, repeatable AWS foundation for sensitive workloads.

It provides a strong starting point for:

- Multi-account AWS structure
- Secure CI/CD access
- Centralized identity
- Private networking
- Logging and monitoring
- Event-driven incident response
- Audit-readiness

It should be adopted thoughtfully, validated carefully, and customized to match the organization’s operational and security requirements.