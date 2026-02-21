# Architecture Overview — terraform-secure-baseline

## Purpose

This document describes the high-level architecture implemented by terraform-secure-baseline and how its components work together to support secure cloud environments.

It focuses on system relationships rather than implementation details.

---

## Core Design Principles

The baseline is designed around:

- Private-by-default infrastructure
- Centralized visibility
- Detection integrity
- Controlled egress
- Automated containment

---

## Networking

The environment is deployed within a segmented VPC structure.

Workloads are placed in private subnets and do not receive public IP addresses.

Access to AWS services occurs through VPC Interface Endpoints where available rather than public internet paths.

Outbound traffic is restricted to:

- VPC Endpoints
- Approved AWS services
- Authorized internal resources

---

## Centralized Logging

Operational activity is captured through:

- CloudTrail
- AWS Config
- VPC Flow Logs

Logs are:

- Stored centrally
- Encrypted
- Versioned
- Object-locked
- Protected against tampering

This supports monitoring continuity and forensic readiness.

---

## Detection Layer

Continuous monitoring is enabled through:

- GuardDuty
- Security Hub
- AWS Config

CloudTrail and EventBridge are used to surface security-relevant activity and configuration changes.

These services provide visibility into:

- Suspicious behavior
- Misconfiguration
- Policy violations

---

## Monitoring Integrity

The baseline includes tamper detection mechanisms that monitor for attempts to modify or disable:

- Logging
- Detection services
- Encryption controls

Alerts are generated in near real-time when such changes are detected.

---

## Response Layer

## Response Layer

The baseline includes an automated response capability for high- and critical-severity EC2 security findings.

Security Hub findings can trigger event-driven containment actions that isolate affected instances from active network access.

This is implemented through controlled automation workflows that:

- Remove existing security group associations
- Apply quarantine controls
- Tag affected resources for visibility

Authorized operators can later initiate controlled recovery actions.

This enables rapid containment while maintaining human oversight of restoration.

---

## Configuration Monitoring

AWS Config continuously evaluates infrastructure posture against defined rules.

This supports:

- Exposure prevention
- Encryption enforcement
- Monitoring consistency

---

## Encryption

Operational logs are protected using:

- KMS-backed encryption
- Key rotation
- Immutable storage controls for operational logs

This supports confidentiality and evidence integrity.

---

## Role Within A Security Program

terraform-secure-baseline provides:

A deployable infrastructure security foundation.

It complements:

- Application security controls
- Identity governance
- Organizational policies