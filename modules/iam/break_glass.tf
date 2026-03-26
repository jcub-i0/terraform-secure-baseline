##########################################
# BREAK-GLASS ADMIN ROLE
##########################################
# This role is intended for emergency use only.
# It should only be used if IAM Identity Center (SSO) is unavailable.
# All usage should be monitored and audited.

resource "aws_iam_role" "break_glass_admin" {
  name = "BreakGlass-Admin"
  description = "Emergency-only administrator role to be used if IAM Identity Center access is unavailable"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
        {
            Sid = "AllowEmergencyAssumeRoleWithMFA"
            Effect = "Allow"
            Principal = {
                AWS = var.break_glass_trusted_principal_arns
            }
            Action = "sts:AssumeRole"
            Condition = {
                Bool = {
                    "aws:MultiFactorAuthPresent" = "true"
                }
            }
        }
    ]
  })

  tags = {
    Name = "BreakGlass-Admin"
    Environment = var.environment
    Terraform = "true"
    Purpose = "EmergencyAccessOnly"
  }
}

resource "aws_iam_role_policy_attachment" "break_glass_admin_access" {
  role = aws_iam_role.break_glass_admin.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}