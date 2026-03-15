# Security Policy

## Overview

This repository contains infrastructure-as-code used to deploy a secure AWS baseline environment for SaaS workloads handling sensitive data such as PII.

Security is a core focus of this project. The infrastructure includes controls such as:

- least-privilege IAM
- private compute workloads
- restricted outbound internet access
- centralized logging
- automated security detection
- automated incident response
- continuous compliance monitoring

## Supported Versions

The `main` branch contains the currently supported configuration.

| Version | Supported |
|--------|-----------|
| main | ✅ Supported |
| older branches | ❌ Not supported |

## Reporting a Vulnerability

If you discover a security vulnerability in this repository, **please report it privately**.

**Do not open public GitHub issues for security vulnerabilities.**

Public disclosure of vulnerabilities before a fix is available can put users of this repository at risk.

Instead, please report vulnerabilities through one of the following channels:

- GitHub Security Advisories (preferred)
- Direct contact with the repository maintainer

When submitting a vulnerability report, please include:

- a clear description of the vulnerability
- affected files or modules
- potential impact
- reproduction steps if applicable
- suggested mitigation if known

## Responsible Disclosure

Please allow reasonable time for the vulnerability to be investigated and resolved before publicly disclosing the issue.

The goal is to protect users of this project while remediation is implemented.

## Security Best Practices

When using this repository, follow these guidelines:

- Never commit credentials, secrets, or API keys to the repository.
- Store sensitive values in AWS Secrets Manager or AWS Systems Manager Parameter Store.
- Review Terraform plans before applying changes.
- Restrict IAM permissions to the minimum required.
- Monitor security findings using AWS Security Hub and GuardDuty.

## Scope

This repository focuses on **infrastructure-level security controls**, including:

- IAM design
- network segmentation
- firewall enforcement
- logging and monitoring
- automated incident response

Application-layer security is outside the scope of this project.