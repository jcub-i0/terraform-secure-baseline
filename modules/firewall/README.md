# AWS Network Firewall Module

## Overview

The `firewall` module implements **centralized outbound traffic inspection and control** using **AWS Network Firewall**.

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

This provides a strong security posture appropriate for SaaS environments handling **sensitive data (PII)**.

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

This makes the rule-evaluation order explicit and reviewable in Terraform.

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

AWS Network Firewall log delivery is asynchronous rather than immediate.
[AWS documents](https://docs.aws.amazon.com/network-firewall/latest/developerguide/firewall-logging-timing.html)
typical delivery averages of roughly **8–12 minutes to Amazon S3** and **3–6
minutes to CloudWatch Logs**, although longer delays can occur.

Flow logs stored in S3 use a structure similar to:

```text
s3://<centralized-logs-bucket>/<prefix>/AWSLogs/<account-id>/network-firewall/flow/<region>/<firewall-name>/
```

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

They are well suited for long-term storage and integration with analytics platforms such as:

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

Many AWS environments rely on security groups to restrict outbound traffic. However, security groups alone cannot:

- Filter traffic based on **domain names**
- Provide **deep packet inspection**
- Generate **network-level security logs**
- Enforce **centralized egress policy**

AWS Network Firewall solves these limitations by introducing a **dedicated inspection layer**.

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

The firewall module strengthens several security controls commonly required for:

- SOC 2
- ISO 27001
- HIPAA-style environments

Relevant control categories include:

- Network segmentation
- Data exfiltration prevention
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

The current ephemeral development/test model sets all three Network Firewall
protection flags to `false` with `# CHANGE THIS IN PROD` comments:

```hcl
delete_protection                 = false
firewall_policy_change_protection = false
subnet_change_protection          = false
```

Persistent production deployments must deliberately review those settings.
