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

### How to Use

The `BreakGlass-Admin` role is intended for **emergency use only** when IAM Identity Center (SSO) is unavailable or misconfigured.

### Prerequisites

- A trusted IAM user (e.g., `baseline-admin`) is configured in:
  - `break_glass_trusted_principal_arns`
- MFA is enabled on the trusted IAM user
- The user has permission to call `sts:AssumeRole` on `BreakGlass-Admin`

---

### Console Usage

1. Sign in to the AWS Console using the trusted IAM user
2. In the top-right menu, select **Switch Role**
3. Enter:
   - **Account ID**: `<your-account-id>`
   - **Role name**: `BreakGlass-Admin`
4. Complete MFA when prompted

You will now have administrative access via the break-glass role.

---

### CLI Usage

Run the following command using the trusted IAM user credentials:

```bash
aws sts assume-role \
  --role-arn arn:aws:iam::<account-id>:role/BreakGlass-Admin \
  --role-session-name breakglass-session \
  --serial-number arn:aws:iam::<account-id>:mfa/<name-of-auth-device> \
  --token-code <MFA-CODE>
```

Export the returned credentials:

```bash
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_SESSION_TOKEN=...
```

#### Verify access:

```bash
aws sts get-caller-identity
```

Expected output:

```json
{
    "UserId": "<AWS_ACCESS_KEY_ID>:breakglass-test",
    "Account": "<ACCOUNT-ID>",
    "Arn": "arn:aws:sts::<ACCOUNT-ID>:assumed-role/BreakGlass-Admin/breakglass-session"
}
```

#### Validation

- Confirm the role was assumed successfully
- Verify administrative actions can be performed
- Confirm an alert was sent to the SecOps SNS topic

---

### Important Notes

- This role is **NOT intended for daily use**
- All usage should be considered **highly sensitive and audited**
- Access should be revoked **immediately after the emergency is resolved**