# IAM Module

## Break-Glass Access

The 'BreakGlass-Admin' role provides emergency administration access in the event that IAM Identity Center (SSO) is unavailable.

This role is:

- Restricted to a small set of trusted principals
- Protected by MFA enforcement
- Intended for emergency use only
- Monitored via logging and alerting

### Trusted Principal

The role is assumed by one or more IAM principals provided via:

`break_glass_trusted_principal_arns`

In production environments, this should reference a dedicated emergency IAM user with:

- MFA enabled
- No routine use
- Credentials stored securely

> ⚠️ This module does NOT create the break-glass IAM user. This is intentional and must be managed by the deploying organization.