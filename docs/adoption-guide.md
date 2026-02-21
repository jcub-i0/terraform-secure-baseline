# Adoption Guide — terraform-secure-baseline

## Purpose

This guide explains when terraform-secure-baseline is appropriate to deploy and what types of environments benefit most from its use.

It is intended to help teams determine whether this baseline aligns with their infrastructure maturity, security needs, and operational goals.

---

## When To Use This Baseline

terraform-secure-baseline is designed for environments that:

- Handle customer data (e.g., PII)
- Require centralized logging
- Need continuous monitoring
- Are preparing for security reviews or audits

It is particularly suited for:

- Early-to-mid-stage SaaS companies
- Growing infrastructure teams
- Organizations formalizing their security posture

---

## Problems This Helps Solve

This baseline helps address common infrastructure risks such as:

- Public exposure of workloads
- Lack of centralized logging
- Undetected configuration drift
- Monitoring gaps
- Limited incident containment capability

---

## What It Provides

Deploying this baseline enables:

- Private-by-default workloads
- Centralized operational evidence
- Continuous detection capability
- Automated containment for HIGH- and CRITICAL-severity findings
- Configuration monitoring
- Encryption-backed log integrity

---

## When It May Not Be Necessary

This baseline may be less relevant for:

- Fully air-gapped environments
- Short-lived experimental environments that are not intended for persistent workloads
- Highly customized enterprise security architectures

---

## Role In A Security Program

terraform-secure-baseline should be viewed as:

A deployable infrastructure security foundation.

It complements:

- Application security controls
- Identity governance
- Organizational policies