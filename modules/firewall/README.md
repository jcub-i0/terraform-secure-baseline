# AWS Network Firewall Module

## Overview

The `firewall` module implements **outbound traffic inspection and control within one workload VPC** using **AWS Network Firewall**.

This reference describes `v1.11.0-rc1`. The firewall is workload-account infrastructure, not a cross-account inspection service deployed in `security-operations`. Baseline instantiates it only when `effective_egress_mode = "network_firewall"`.

It exists to address a key security challenge in cloud environments: how to
allow reviewed workload internet access without permitting unrestricted
outbound connectivity.

In many AWS environments, workloads are placed in private subnets but still have unrestricted outbound access through a NAT Gateway. While this prevents inbound internet exposure, it does **not** restrict outbound destinations.

This module introduces a **controlled egress architecture** for environments using
the `network_firewall` egress mode:

- Internet-bound traffic from compute workloads is routed through an **AWS Network Firewall inspection layer**
- HTTP and HTTPS destinations are restricted through an explicitly reviewed domain allowlist
- Traffic that is not permitted by the configured firewall policy is dropped

The broader baseline also supports `nat_only` and `vpc_endpoints_only` egress
modes; those modes do not route workload internet traffic through this module.

This adds one defense-in-depth control for sensitive workloads; it is not a guarantee that all traffic, application content, or data exfiltration is inspected or prevented.

---

## Security Goals

This module helps enforce the following security principles:

✔ **Deny-by-default outbound internet access**
✔ **Centralized network traffic inspection**
✔ **Domain-based allowlisting for updates and dependencies**
✔ **Network-level enforcement independent of instance configuration**
✔ **Auditable firewall logging**

It allows controlled outbound connectivity and reduces exposure to:

- Malware callbacks
- Data exfiltration
- Unauthorized package downloads
- Arbitrary outbound internet access

---

## Architecture

When the baseline's effective egress mode is `network_firewall`, the firewall is
deployed using a **centralized inspection pattern**.

Compute Subnet ➔ Network Firewall endpoint in a firewall subnet ➔ NAT Gateway ➔ Internet Gateway ➔ Internet

In that mode, outbound internet traffic from compute workloads follows this path:

1. **Compute private subnet** routes `0.0.0.0/0` to the **Network Firewall endpoint**
2. The firewall **inspects traffic using configured rule groups**
3. Permitted traffic is forwarded toward the **NAT Gateway**
4. NAT sends traffic to the **Internet Gateway**
5. Return traffic follows the corresponding inspected path back

This preserves the inspected path and AZ-local routing symmetry when Network
Firewall mode is active.

Other baseline egress modes behave differently:

- `nat_only` routes eligible compute-private internet traffic directly through NAT
- `vpc_endpoints_only` creates no general internet default route

---

## What This Module Deploys

### AWS Network Firewall

An AWS Network Firewall resource with firewall endpoints deployed into
**dedicated firewall subnets** across the configured availability zones.

The firewall performs **stateful traffic inspection** and enforces the configured security policy.

---

### Firewall Policy

Defines how traffic is evaluated and processed.

Configures:

- Stateless default actions that forward traffic to the stateful engine
- Stateful rule group enforcement
- Strict rule evaluation order

The RC1 policy forwards both ordinary and fragment stateless defaults to `aws:forward_to_sfe`. The stateful engine and generated domain rule group both use `STRICT_ORDER`; the rule group has capacity `1000` and is referenced at priority `1`. The stateful defaults are:

```hcl
stateful_default_actions = [
  "aws:drop_established",
  "aws:alert_established",
]
```

This is a host/SNI allowlist with the stated defaults. The module does not configure TLS decryption, application authentication, or arbitrary additional rule groups.

---

### Stateful Rule Group (Domain Allowlist)

Implements domain-based filtering for outbound traffic.

The rule group uses a **generated allowlist** based on:

- TLS SNI
- HTTP host headers

`baseline/locals.tf` computes the effective allowlist as the union of:

- Baseline-owned platform-required domains for Ubuntu package repositories and
  secure OS patching.
- Environment-approved application domains supplied through
  `allowed_egress_domains`.

The application set defaults to empty. Callers do not repeat platform domains,
and the module contains no customer-specific defaults. Baseline passes the
final `local.effective_allowed_egress_domains` set to this module as
`allowed_egress_domains`; `aws_networkfirewall_rule_group.stateful_domains`
uses that value directly. AWS Network Firewall domain-list syntax is preserved:
an exact name matches that name, while an initial dot matches the name and its
subdomains.

Example:
```text
.archive.ubuntu.com
.security.ubuntu.com
.ubuntu.com
```
This allows necessary system updates and explicitly reviewed application
dependencies while restricting HTTP/HTTPS destinations evaluated through TLS SNI
and HTTP host headers. AWS Network Firewall domain-list inspection does not
perform DNS resolution for this control, so non-HTTP/S or IP-based policy needs
must be handled by other firewall rules where required.

The input only changes the Network Firewall allowlist when that firewall is
instantiated; it does not alter routing or create an internet path for
`vpc_endpoints_only`.

---

### Firewall Logging

Two types of logs are enabled:

| Log Type | Destination | Purpose |
|---|---|---|
| Flow Logs | S3 | Long-term traffic flow visibility |
| Alert Logs | CloudWatch Logs | Operational firewall alert events |

### Flow Log Behavior

The module configures destinations, not a delivery-latency guarantee. Do not use an immediate absence of log objects as proof that routing is broken. Check actual delivery and the service's logging status separately from Terraform configuration.

The configured S3 destination prefix is exactly:

```text
<cloud_name>/firewall/flow
```

The [storage bucket policy](../storage/main.tf) authorizes the corresponding object scope:

```text
s3://<centralized-logs-bucket>/<cloud_name>/firewall/flow/AWSLogs/<account-id>/*
```

Do not omit `cloud_name` when aligning the delivery destination and policy. The alert log-group name defaults to `/aws/firewall/egress`; retention and its KMS key are supplied by the caller.

Flow logs contain **network connection metadata**, including fields such as:

- Source and destination IP addresses
- Source and destination ports
- Protocol
- Packet and byte counts
- Flow start and end times

Action/verdict information is associated with rule evaluation and alert events
and should not be treated as a guaranteed field of every flow record.

These logs support retrospective traffic investigation and forensic analysis;
they are not a synchronous alerting mechanism.

Flow records are generated by the firewall's stateful inspection engine.
Alert logs are generated when configured stateful rules or alert-capable firewall
actions produce alert events. A dropped packet is not automatically guaranteed
to produce an alert record unless the policy/rule behavior is configured to log
that event.

CloudWatch delivery is asynchronous and should not be treated as an immediate
notification path.

Downstream analytics integrations could consume these logs, but this module does not provision query or ingestion integrations for:

- Amazon Athena
- OpenSearch
- SIEM platforms

### Logging Strategy

This logging architecture provides both:

- **Operational monitoring** through the CloudWatch Logs alert-event stream
- **Forensic visibility** through long-term flow logs stored in S3

Terraform configures the `FLOW` stream for S3 and the `ALERT` stream for a
KMS-encrypted CloudWatch log group. It does not configure the separate `TLS`
log type. Successful S3 delivery also depends on the destination bucket and
KMS policies authorizing the exact generated object prefix.

---

## Integration with the Networking Module

This module relies on the networking module to:

- Create **dedicated firewall subnets**
- Route compute subnet traffic to **firewall endpoints**
- Route firewall traffic to **NAT gateways**
- Maintain **AZ-local routing symmetry**

When `network_firewall` mode is active, Terraform configures routing so that:

✔ Internet-bound compute traffic follows the firewall inspection path
✔ AZ-local routing symmetry is maintained
✔ Firewall endpoints are distributed across configured AZs for high availability

---

## Why This Module Exists

The baseline security-policy layer controls ports and approved security-group or prefix-list relationships. This module adds the separate stateful HTTP-host/TLS-SNI destination policy and firewall log destinations. It does not replace IAM, private endpoint policy, application controls, or the security-group layer.

This module gives the baseline a reviewed, domain-restricted outbound control
for the protocols evaluated by the configured domain-list rule group.

---

## Security Model

When `network_firewall` mode is active, outbound internet access is governed by
three layers:

### 1. Security Groups

Application/task security-group policy is intentionally restrictive and
typically permits only the egress needed by the selected workload mode and
declared dependencies.

For internet-capable ECS application egress, the generic HTTPS rule is:

443 -> 0.0.0.0/0

That security-group rule permits HTTPS at the network layer; route tables and,
when active, Network Firewall policy still determine whether a destination is
actually reachable.

---

### 2. Route Tables

In `network_firewall` mode, the compute-private default route points to the
Network Firewall endpoint so general internet-bound compute traffic follows the
inspection path.

This statement does not apply to `nat_only` or `vpc_endpoints_only`, which use
different routing behavior.

---

### 3. Network Firewall Rules

The stateful domain allowlist restricts HTTP/HTTPS destinations using HTTP host
headers and TLS SNI.

Other protocols or destination controls remain governed by the rest of the
configured firewall policy.

---

## Compliance Benefits

The configured resources can support an organization's technical control narratives. They do not establish certification, audit compliance, or application-level protection by themselves.

Relevant implementation areas include:

- Network segmentation
- Reviewed outbound destination restrictions
- Controlled outbound connectivity
- Security monitoring
- Logging and auditability

---

## Design Philosophy

This module prioritizes:

✔ **Secure-by-default networking**
✔ **Minimal operational complexity**
✔ **Strong outbound control without breaking workloads**

When Network Firewall mode is active, baseline composition retains the
platform-required domains needed for system updates and combines them with any
explicitly approved environment application domains. Environment owners can
leave the application set empty to preserve platform-only allowlist behavior.

---

## Intended Use

This module is designed for:

- Secure SaaS infrastructure baselines
- Environments processing **customer PII**
- Cloud security consulting engagements
- Organizations implementing **defense-in-depth network controls**

It provides a defense-in-depth egress control while remaining compatible with
automated infrastructure deployment using Terraform.

## Current destruction posture

RC1 separates resource deletion protection from policy/subnet-change protection:

| Setting | RC1 module behavior | Baseline behavior |
|---|---|---|
| `delete_protection` | Required caller input | `true` for normal production; `false` for retirement and non-production |
| `firewall_policy_change_protection` | Literal `false` | Not overridden by deployment profile |
| `subnet_change_protection` | Literal `false` | Not overridden by deployment profile |

Only deletion protection is profile/retirement-driven. The remaining `CHANGE THIS IN PROD` comments do not enable anything automatically. The firewall resource also declares `create_before_destroy = true`; that is not a substitute for native deletion protection or a guarantee that every replacement will succeed.

Production retirement must relax deletion protection through the reviewed Stage-1 Apply before the saved destroy plan is applied. Follow the [retirement runbook](../../docs/production-retirement.md); do not change the deployment profile to bypass protection.

## Inputs

These are the actual low-level module inputs, not a second set of deployment-profile defaults.

| Input | Type | Required | Default | Purpose |
|---|---|---:|---|---|
| `cloud_name` | `string` | Yes | — | S3 flow-log prefix |
| `name_prefix` | `string` | Yes | — | Firewall, policy, rule-group names and tags |
| `environment` | `string` | Yes | — | Environment tags |
| `vpc_id` | `string` | Yes | — | Workload VPC |
| `firewall_private_subnet_ids_map` | `map(string)` | Yes | — | Firewall subnet IDs keyed by AZ |
| `logs_cmk_arn` | `string` | Yes | — | Alert log-group CMK |
| `cloudwatch_retention_days` | `string` | Yes | — | Declared string input for log retention; baseline passes its effective day count |
| `network_firewall_log_group_name` | `string` | No | `/aws/firewall/egress` | Alert log-group name |
| `allowed_egress_domains` | `set(string)` | No | `[]` | Final rule-group targets; baseline passes the platform/application union |
| `centralized_logs_bucket_arn` | `string` | Yes | — | Retained interface input; not referenced by `main.tf` |
| `centralized_logs_bucket_name` | `string` | Yes | — | S3 flow-log destination bucket |
| `delete_protection` | `bool` | Yes | — | Native firewall deletion protection |

Domain-input validation rejects empty or whitespace-bearing values, URL/path syntax, wildcards, IP-address forms, and CIDR syntax. The module does not add platform domains itself. A direct caller must provide its complete intended domain set; the baseline performs the platform-domain union in [locals.tf](../../baseline/locals.tf).

## Outputs

| Output | Meaning |
|---|---|
| `firewall_arn` | Firewall ARN |
| `firewall_name` | Firewall name |
| `firewall_status` | Resource-backed firewall status structure |
| `sync_states` | Resource-backed synchronization states |
| `firewall_endpoint_ids_by_az` | AZ-to-endpoint-ID map consumed by networking |
| `effective_allowed_egress_domains` | Resource-backed generated domain targets |

## Baseline Topology and Validation

Production defaults place firewall endpoints across three `firewall_private` subnets. Compute-private default routes point to the same-AZ firewall endpoint; firewall-private defaults point to the same-AZ NAT in `egress_public`. Only egress-public route tables carry the corresponding compute-CIDR return routes. `ingress_public` is separate and does not redirect ALB-to-task traffic through this firewall path.

Private Interface Endpoint traffic and the configured S3 Gateway Endpoint path are distinct from the compute default-internet route. Do not describe this module as inspecting every packet in the VPC.

`validate-networking.sh` checks the live firewall's expected existence, readiness/placement, deletion protection, effective domain targets, and exact surrounding routing against Terraform. It is not an application penetration test or a complete firewall-rule behavioral test. Firewall log delivery also depends on the separately owned logs bucket and KMS policies.

Implementation references: [resources](main.tf), [inputs](variables.tf), [outputs](outputs.tf), [networking](../networking/README.md), and [networking validator](../../scripts/validation/validate-networking.sh).
