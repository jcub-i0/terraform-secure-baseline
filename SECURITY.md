# Security Policy

## Overview

This repository contains Terraform, deployment workflows, validation tooling, and
security-response functions for AWS workloads handling sensitive data. Its controls
include account/role separation, private workload networking, configurable egress,
logging, security-service integration, and selected response automation.

Control presence is not a guarantee of security or a complete compliance program.
Review the [architecture](docs/architecture-overview.md),
[adoption requirements](docs/adoption-guide.md), and
[control narratives](docs/assurance/control-narratives.md), including their known
permission, preservation, response, and validation boundaries.

<a id="supported-versions"></a>

## Maintenance Scope

Maintenance tracks the `main` branch. Older branches are not supported as separate
maintenance lines. Identify the exact commit and affected configuration in a report;
`main` is a moving reference, not a reproducible deployment identifier or an assurance
that every reported issue has been resolved.

This document specifies no response deadline, remediation deadline, service-level
agreement, or bounty. Any separate licensing or support commitments are governed by
the applicable written agreement, not by this policy.

## Reporting a Vulnerability

Report suspected vulnerabilities privately. **Do not disclose vulnerability details,
exploit payloads, credentials, customer data, state files, or sensitive evidence in a
public GitHub issue or pull request.**

Use GitHub's private vulnerability-reporting form when it is available in the
repository's Security area. A `SECURITY.md` file does not itself enable that feature.
See [GitHub's private reporting instructions](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/report-privately).

When that form is unavailable, use an established private contact with the repository
maintainer. This policy does not publish an alternative email address or encryption
key; confirm the private channel before sending sensitive material. Do not treat a
missing private form as permission to disclose the vulnerability publicly.

Include enough information to reproduce and assess the finding:

- The affected commit, files/modules, non-secret configuration, account/Region context,
  and relevant workflow or validator behavior.
- Expected versus observed behavior, prerequisites, a minimal authorized reproduction,
  and the security impact or boundary crossed.
- Sanitized logs or evidence, known mitigations, and whether the issue was observed in
  a deployed environment or inferred from source inspection.

Clearly distinguish a code defect, a configuration-dependent limitation, a documentation
error, and a weakness in a deployed organization's operating process. A previously
recorded limitation can still merit a private report when new evidence changes its
impact. Do not submit customer data or working secrets to demonstrate that impact.

## Responsible Disclosure

Allow reasonable time for investigation and coordinate disclosure with the maintainer
while remediation or mitigations are considered. Preserve enough non-sensitive
provenance to distinguish the affected deployment from later code changes.

Testing must stay within systems and resources you are authorized to assess. Prefer
source inspection and isolated test environments. Do not disable logging, change
production access, invoke containment/rollback, or delete resources merely to produce
a demonstration without explicit authorization from the affected resource owner.

This policy is a reporting procedure, not permission to test third-party systems or
a grant of software-use rights. Usage remains subject to [LICENSE](LICENSE).

## Security Best Practices

For an authorized deployment:

- Keep credentials, API keys, private keys, state, binary plans, and sensitive evidence
  out of source control and public reports. Distinguish intentionally tracked,
  non-secret workload configuration from ignored runtime input files.
- Review the exact Terraform plan and effective account, Region, IAM permissions,
  OIDC subjects, and GitHub Environment protections before Apply. Plan/Apply role
  separation does not mean both roles have narrow privileges.
- Select response authorization, Config remediation scope, logging/key preservation,
  backup/restore acceptance, notification consumers, and retirement approvals before
  operating the environment. Neither an empty DLQ nor a validator PASS establishes
  successful business operations or recoverability.
- Review GuardDuty, Security Hub, Inspector, Config, logs, alerts, and exceptions with
  named owners. Application authorization, tenant isolation, secrets handling,
  database access, and transport protection require application-specific controls.

Use the [validation checklist](docs/validation-checklist.md) and
[evidence guide](docs/assurance/validation-evidence-guide.md) for the distinction
between configuration assertions, warnings/skips, behavioral exercises, and ongoing
operating evidence. Follow the [retirement runbook](docs/production-retirement.md)
for approved production teardown rather than weakening protections ad hoc.

## Scope

Repository security review includes the infrastructure definitions and their supporting
code: IAM and resource policies, networking, logging/monitoring, response functions,
CI/CD authentication and artifacts, state handling, validation, and operating guidance.

Application-specific security and an adopting organization's human processes are not
implemented by this repository. An active incident in a deployed environment also
requires that organization's incident-response process; a repository vulnerability
report is not a substitute for operational incident handling.
