# Quickstart — terraform-secure-baseline

## Purpose

This guide provides the fastest path to deploying terraform-secure-baseline and validating that core security controls are functioning as intended.

It is designed to help teams quickly verify that:

- Workloads operate without public internet dependency
- AWS service access occurs via VPC Interface Endpoints
- Monitoring and containment capabilities are operational

---

## Prerequisites

Ensure the following are installed and configured:

- Terraform (v1.5+ recommended)
- AWS CLI
- AWS credentials with sufficient permissions configured for your target account

Verify access:

```bash
aws sts get-caller-identity
```

## Clone Repository

```bash
git clone https://github.com/jcub-i0/terraform-secure-baseline.git
cd terraform-secure-baseline
```

## Deploy

terraform-secure-baseline is designed to deploy using sensible defaults.

By default, it will:

- Deploy into `us-east-1`
- Create a VPC (`10.0.0.0/16`)
- Use two AZs
- Enable core detection and protection rules

Only one input is required:

### Required (No Default)

Provide at apply time:

- `bucket_admin_principles`

Optional (recommended):

- `secops_emails` (to receive security alerts)

Initialize Terraform:
> Ensure AWS credentials are configured (environment variables, profile, or SSO)
```bash
terraform init
```

Preview the deployment:
```bash
terraform plan
```

Apply the environment:
> Replace placeholder values before running

```bash
terraform apply \
  -var='bucket_admin_principles=["arn:aws:iam::<ACCOUNT_ID>:root"]' \
  -var='secops_emails=["<EMAIL_ADDRESS>"]'
```

> NOTE:
> Some AWS resources are created in stages due to dependency ordering.
> If Terraform indicates additional changes after the first apply, simply run:
```bash
terraform apply
```

## Validate Deployment

After deployment completes, run through:

`/docs/validation-checklist.md`