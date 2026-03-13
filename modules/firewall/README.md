# AWS Network Firewall Module

## Overview

The `firewall` module implements **centralized outbound traffic inspection and control** using **AWS Network Firewall**.

It exists to solve a key security challenge in cloud environments: How to allow workloads to access the internet **safely** without permitting unrestricted outbound connectivity.

In many AWS environments, workloads are placed in private subnets but still have unrestricted outbound access through a NAT Gateway. While this prevents inbound internet exposure, it does **not** restrict outbound destinations.

This module introduces a **controlled egress architecture** where:

- All outbound internet traffic from compute workloads is routed through a **Network Firewall inspection layer**
- Only **explicitly approved domains** are reachable
- All other traffic is **blocked by default**

This provides a strong security posture appropriate for SaaS environments handling **sensitive data (PII)**.

---

## Security Goals

This module helps enforce the following security principles:

✔ **Deny-by-default outbound internet access**  
✔ **Centralized network traffic inspection**  
✔ **Domain-based allowlisting for updates and dependencies**  
✔ **Network-level enforcement independent of instance configuration**  
✔ **Auditable firewall logging**

It allows controlled outbound connectivity while preventing:

- Malware callbacks
- Data exfiltration
- Unauthorized package downloads
- Arbitrary outbound internet access

---

## Architecture

The firewall is deployed using a **centralized inspection pattern**.
|Compute Subnet|
▼
Network Firewall Endpoint
│
▼
Firewall Subnet
│
▼
NAT Gateway
│
▼
Internet Gateway
│
▼
Internet

Outbound traffic from compute workloads follows this path:

1. **Compute private subnet** routes `0.0.0.0/0` to the **Network Firewall endpoint**
2. The firewall **inspects traffic using configured rule groups**
3. Approved traffic is forwarded to the **NAT Gateway**
4. NAT sends traffic to the **Internet Gateway**
5. Return traffic follows the **same path back**

This ensures all internet-bound traffic is inspected.

---

## What This Module Deploys

### AWS Network Firewall

A regional firewall instance deployed into **dedicated firewall subnets** across all configured availability zones.

The firewall performs **stateful traffic inspection** and enforces the configured security policy.

---

### Firewall Policy

Defines how traffic is evaluated and processed.

Includes:

- Stateless forwarding rules
- Stateful rule group enforcement
- Strict rule evaluation order

This ensures traffic is inspected **deterministically and consistently**.

---

### Stateful Rule Group (Domain Allowlist)

Implements domain-based filtering for outbound traffic.

The rule group uses a **generated allowlist** based on:

- TLS SNI
- HTTP host headers

Example allowed domains include Ubuntu package repositories required for secure OS patching.

Example:

.archive.ubuntu.com
.security.ubuntu.com
.ubuntu.com

This allows necessary system updates while preventing access to arbitrary external domains.

---

### Firewall Logging

Two types of logs are enabled:

| Log Type | Destination | Purpose |
|---|---|---|
| Flow Logs | S3 | Full traffic flow visibility |
| Alert Logs | CloudWatch | Real-time security alerts |

This provides both:

- **Forensic visibility**
- **Operational monitoring**

Logs are integrated with the centralized logging architecture used by the rest of the environment.

---

## Integration with the Networking Module

This module relies on the networking module to:

- Create **dedicated firewall subnets**
- Route compute subnet traffic to **firewall endpoints**
- Route firewall traffic to **NAT gateways**
- Maintain **AZ-local routing symmetry**

Proper routing ensures:

✔ Traffic is always inspected  
✔ No asymmetric routing occurs  
✔ High availability across AZs  

---

## Why This Module Exists

Many AWS environments rely on security groups to restrict outbound traffic. However, security groups alone cannot:

- Filter traffic based on **domain names**
- Provide **deep packet inspection**
- Generate **network-level security logs**
- Enforce **centralized egress policy**

AWS Network Firewall solves these limitations by introducing a **dedicated inspection layer**.

This module allows the baseline architecture to enforce a **true least-privilege outbound network policy**.

---

## Security Model

Outbound internet access is governed by three layers:

### 1. Security Groups

Workloads can only initiate outbound HTTPS connections.

Example:

443 -> 0.0.0.0/0


This permits encrypted outbound traffic only.

---

### 2. Route Tables

All outbound traffic is forced through the firewall inspection layer.

Compute subnets cannot bypass the firewall.

---

### 3. Network Firewall Rules

Domain allowlists restrict outbound destinations.

Only approved update and dependency domains are reachable.

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

The domain allowlist begins with only the **minimum required domains for system updates** and can be extended as necessary.

---

## Intended Use

This module is designed for:

- Secure SaaS infrastructure baselines
- Environments processing **customer PII**
- Cloud security consulting engagements
- Organizations implementing **defense-in-depth network controls**

It provides a **production-grade egress security layer** while remaining compatible with automated infrastructure deployment using Terraform.