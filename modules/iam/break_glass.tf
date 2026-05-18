##########################################
# BREAK-GLASS ADMIN ROLE
##########################################
# This role is intended for emergency use only.
# It should only be used if IAM Identity Center (SSO) is unavailable.
# All usage should be monitored and audited.

data "aws_iam_policy_document" "break_glass_admin_assume_role" {
  statement {
    sid     = "AllowEmergencyAssumeRoleWithMFA"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = var.break_glass_trusted_principal_arns
    }

    condition {
      test     = "Bool"
      variable = "aws:MultiFactorAuthPresent"
      values   = ["true"]
    }
  }
}

# BREAK-GLASS ADMIN ROLE
resource "aws_iam_role" "break_glass_admin" {
  name        = "${var.name_prefix}-BreakGlass-Admin"
  description = "Emergency-only administrator role to be used if IAM Identity Center access is unavailable"

  assume_role_policy = data.aws_iam_policy_document.break_glass_admin_assume_role.json

  tags = {
    Name        = "${var.name_prefix}-BreakGlass-Admin"
    Environment = var.environment
    Terraform   = "true"
    Purpose     = "EmergencyAccessOnly"
  }
}

resource "aws_iam_role_policy_attachment" "break_glass_admin_access" {
  role       = aws_iam_role.break_glass_admin.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}