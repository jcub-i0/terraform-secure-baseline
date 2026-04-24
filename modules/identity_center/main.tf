# IAM IDENTITY CENTER (SSO) RESOURCES

##########################################
# IAM IDENTITY CENTER - DISCOVER INSTANCE
##########################################

data "aws_ssoadmin_instances" "this" {}

locals {
  instance_arn      = tolist(data.aws_ssoadmin_instances.this.arns)[0]
  identity_store_id = tolist(data.aws_ssoadmin_instances.this.identity_store_ids)[0]
}

##########################################
# CREATE IAM IDENTITY CENTER GROUPS
##########################################

resource "aws_identitystore_group" "secops_analyst" {
  count = var.enable_secops_analyst ? 1 : 0

  identity_store_id = local.identity_store_id
  display_name      = var.secops_analyst_group_name
  description       = "SecOps-Analysts Identity Center group"
}

resource "aws_identitystore_group" "secops_engineers" {
  count = var.enable_secops_engineer ? 1 : 0

  identity_store_id = local.identity_store_id
  display_name      = var.secops_engineer_group_name
  description       = "SecOps-Engineers Identity Center group"
}

resource "aws_identitystore_group" "secops_operators" {
  identity_store_id = local.identity_store_id
  display_name      = var.secops_operator_group_name
  description       = "SecOps-Operators Identity Center Group"
}

##########################################
# PERMISSION SETS
##########################################

resource "aws_ssoadmin_permission_set" "secops_analyst" {
  count = var.enable_secops_analyst ? 1 : 0

  name             = "SecOps-Analyst-${var.environment}"
  description      = "Read-only security visibility for analysts"
  instance_arn     = local.instance_arn
  session_duration = "PT4H"
}

resource "aws_ssoadmin_permission_set" "secops_engineer" {
  count = var.enable_secops_engineer ? 1 : 0

  name             = "SecOps-Engineer-${var.environment}"
  description      = "Security investigation and response access"
  instance_arn     = local.instance_arn
  session_duration = "PT4H"
}

resource "aws_ssoadmin_permission_set" "secops_operator" {
  name             = "SecOps-Operator-${var.environment}"
  description      = "Privileged operational rollback access"
  instance_arn     = local.instance_arn
  session_duration = "PT2H"
}

##########################################
# AWS-MANAGED POLICY ATTACHMENTS
##########################################

# SECOPS-ANALYST POLICY ATTACHMENTS

resource "aws_ssoadmin_managed_policy_attachment" "secops_analyst_security_audit" {
  count = var.enable_secops_analyst ? 1 : 0

  instance_arn       = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.secops_analyst[0].arn
  managed_policy_arn = "arn:aws:iam::aws:policy/SecurityAudit"
}

resource "aws_ssoadmin_managed_policy_attachment" "secops_analyst_readonly" {
  count = var.enable_secops_analyst ? 1 : 0

  instance_arn       = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.secops_analyst[0].arn
  managed_policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# SECOPS-ENGINEER POLICY ATTACHMENTS

resource "aws_ssoadmin_managed_policy_attachment" "secops_engineer_security_audit" {
  count = var.enable_secops_engineer ? 1 : 0

  instance_arn       = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.secops_engineer[0].arn
  managed_policy_arn = "arn:aws:iam::aws:policy/SecurityAudit"
}

resource "aws_ssoadmin_managed_policy_attachment" "secops_engineer_readonly" {
  count = var.enable_secops_engineer ? 1 : 0

  instance_arn       = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.secops_engineer[0].arn
  managed_policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

##########################################
# CUSTOMER-MANAGED POLICY ATTACHMENTS
##########################################

# SECOPS-ANALYST POLICY ATTACHMENTS

resource "aws_ssoadmin_customer_managed_policy_attachment" "secops_analyst_logs_s3_read" {
  count = var.logs_s3_readonly_policy_name ? 1 : 0

  instance_arn       = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.secops_analyst[0].arn

  customer_managed_policy_reference {
    name = var.logs_s3_readonly_policy_name
    path = var.customer_managed_policy_path
  }
}

resource "aws_ssoadmin_customer_managed_policy_attachment" "secops_analyst_logs_cmk" {
  count = var.logs_cmk_decrypt_policy_name ? 1 : 0

  instance_arn       = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.secops_analyst[0].arn

  customer_managed_policy_reference {
    name = var.logs_cmk_decrypt_policy_name
    path = var.customer_managed_policy_path
  }
}

# SECOPS-ENGINEER POLICY ATTACHMENTS

resource "aws_ssoadmin_customer_managed_policy_attachment" "secops_engineer_logs_s3_read" {
  count = var.logs_s3_readonly_policy_name ? 1 : 0

  instance_arn       = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.secops_engineer[0].arn

  customer_managed_policy_reference {
    name = var.logs_s3_readonly_policy_name
    path = var.customer_managed_policy_path
  }
}

resource "aws_ssoadmin_customer_managed_policy_attachment" "secops_engineer_logs_cmk" {
  count = var.logs_cmk_decrypt_policy_name ? 1 : 0

  instance_arn       = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.secops_engineer[0].arn

  customer_managed_policy_reference {
    name = var.logs_cmk_decrypt_policy_name
    path = var.customer_managed_policy_path
  }
}

##########################################
# INLINE POLICY FOR SECOPS-ENGINEER
##########################################

resource "aws_ssoadmin_permission_set_inline_policy" "secops_engineer_inline" {
  count = var.enable_secops_engineer ? 1 : 0

  instance_arn       = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.secops_engineer[0].arn

  inline_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowSecurityInvestigation"
        Effect = "Allow"
        Action = [
          "securityhub:BatchUpdateFindings",
          "ec2:CreateTags",
          "ec2:ModifyInstanceAttribute",
          "ec2:ReplaceIamInstanceProfileAssociation",
          "ec2:AssociateIamInstanceProfile",
          "ec2:DisassociateIamInstanceProfile"
        ]
        Resource = "*"
      }
    ]
  })
}

##########################################
# INLINE POLICY FOR SECOPS-OPERATOR
##########################################

resource "aws_ssoadmin_permission_set_inline_policy" "secops_operator_inline" {
  instance_arn       = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.secops_operator.arn

  inline_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowListEventBuses"
        Effect = "Allow"
        Action = [
          "events:ListEventBuses",
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowDescribeAndPutOnSecOpsBus"
        Effect = "Allow"
        Action = [
          "events:DescribeEventBus",
          "events:PutEvents"
        ]
        Resource = var.secops_event_bus_arn
      }
    ]
  })
}

##########################################
# ACCOUNT ASSIGNMENTS
##########################################

resource "aws_ssoadmin_account_assignment" "analysts" {
  count = var.enable_secops_analyst ? 1 : 0

  instance_arn       = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.secops_analyst[0].arn

  principal_id   = aws_identitystore_group.secops_analyst.group_id
  principal_type = "GROUP"

  target_id   = var.account_id
  target_type = "AWS_ACCOUNT"

  depends_on = [
    aws_ssoadmin_managed_policy_attachment.secops_analyst_security_audit,
    aws_ssoadmin_managed_policy_attachment.secops_analyst_readonly,
    aws_ssoadmin_customer_managed_policy_attachment.secops_analyst_logs_s3,
    aws_ssoadmin_customer_managed_policy_attachment.secops_analyst_logs_cmk
  ]
}

resource "aws_ssoadmin_account_assignment" "engineers" {
  count = var.enable_secops_engineer ? 1 : 0

  instance_arn       = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.secops_engineer[0].arn

  principal_id   = aws_identitystore_group.secops_engineers.group_id
  principal_type = "GROUP"

  target_id   = var.account_id
  target_type = "AWS_ACCOUNT"

  depends_on = [
    aws_ssoadmin_managed_policy_attachment.secops_engineer_readonly,
    aws_ssoadmin_managed_policy_attachment.secops_engineer_security_audit,
    aws_ssoadmin_customer_managed_policy_attachment.secops_engineer_logs_s3,
    aws_ssoadmin_customer_managed_policy_attachment.secops_engineer_logs_cmk,
    aws_ssoadmin_permission_set_inline_policy.secops_engineer_inline
  ]
}

resource "aws_ssoadmin_account_assignment" "operators" {
  instance_arn       = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.secops_operator.arn

  principal_id   = aws_identitystore_group.secops_operators.group_id
  principal_type = "GROUP"

  target_id   = var.account_id
  target_type = "AWS_ACCOUNT"

  depends_on = [
    aws_ssoadmin_permission_set_inline_policy.secops_operator_inline
  ]
}