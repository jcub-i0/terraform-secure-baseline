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
# GROUP LOOKUPS
##########################################

data "aws_identitystore_group" "secops_analysts" {
  identity_store_id = local.identity_store_id

  alternate_identifier {
    unique_attribute {
      attribute_path  = "Displayname"
      attribute_value = var.secops_analyst_group_name
    }
  }
}

data "aws_identitystore_group" "secops_engineers" {
  identity_store_id = local.identity_store_id

  alternate_identifier {
    unique_attribute {
      attribute_path  = "DisplayName"
      attribute_value = var.secops_engineer_group_name
    }
  }
}

data "aws_identitystore_group" "secops_operators" {
  identity_store_id = local.identity_store_id

  alternate_identifier {
    unique_attribute {
      attribute_path  = "DisplayName"
      attribute_value = var.secops_operator_group_name
    }
  }
}

##########################################
# PERMISSION SETS
##########################################

resource "aws_ssoadmin_permission_set" "secops_analyst" {
  name             = "SecOps-Analyst"
  description      = "Read-only security visibility for analysts"
  instance_arn     = local.instance_arn
  session_duration = "PT4H"
}

resource "aws_ssoadmin_permission_set" "secops_engineer" {
  name             = "SecOps-Engineer"
  description      = "Security investigation and response access"
  instance_arn     = local.instance_arn
  session_duration = "PT4H"
}

resource "aws_ssoadmin_permission_set" "secops_operator" {
  name             = "SecOps-Operator"
  description      = "Privileged operational rollback access"
  instance_arn     = local.identity_store_id
  session_duration = "PT2H"
}

##########################################
# AWS-MANAGED POLICY ATTACHMENTS
##########################################

resource "aws_ssoadmin_managed_policy_attachment" "secops_analyst_security_audit" {
  instance_arn       = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.secops_analyst.arn
  managed_policy_arn = "arn:aws:iam::aws:policy/SecurityAudit"
}

resource "aws_ssoadmin_managed_policy_attachment" "secops_analyst_readonly" {
  instance_arn       = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.secops_analyst.arn
  managed_policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_ssoadmin_managed_policy_attachment" "secops_engineer_security_audit" {
  instance_arn       = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.secops_engineer.arn
  managed_policy_arn = "arn:aws:iam::aws:policy/SecurityAudit"
}

##########################################
# INLINE POLICY FOR SECOPS-ENGINEER
##########################################

resource "aws_ssoadmin_permission_set_inline_policy" "secops_engineer_inline" {
  instance_arn       = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.secops_engineer.arn

  inline_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowSecurityInvestigation"
        Effect = "Allow"
        Action = [
          "securityhub:Get*",
          "securityhub:List*",
          "securityhub:BatchUpdateFindings",
          "guardduty:Get*",
          "guardduty:List*",
          "inspector2:List*",
          "inspector2:Get*",
          "cloudtrail:LookupEvents",
          "config:Get*",
          "config:Describe*",
          "logs:Describe*",
          "logs:Get*",
          "logs:FilterLogEvents",
          "logs:StartQuery",
          "logs:StopQuery",
          "logs:GetQueryResults",
          "ec2:Describe*",
          "ssm:Describe*",
          "ssm:Get*",
          "sns:List*",
          "ec2:Describe*",
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
        Sid    = "AllowRollbackAndResponse"
        Effect = "Allow"
        Action = [
          "events:PutEvents",
          "lambda:InvokeFunction",
        ]
        Resource = "*"
      }
    ]
  })
}

##########################################
# ACCOUNT ASSIGNMENTS
##########################################

resource "aws_ssoadmin_account_assignment" "analysts" {
  instance_arn       = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.secops_analyst.arn

  principal_id   = data.aws_identitystore_group.secops_analysts.group_id
  principal_type = "GROUP"

  target_id   = var.account_id
  target_type = "AWS_ACCOUNT"
}

resource "aws_ssoadmin_account_assignment" "engineers" {
  instance_arn       = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.secops_engineer.arn

  principal_id   = data.aws_identitystore_group.secops_engineers.group_id
  principal_type = "GROUP"

  target_id   = var.account_id
  target_type = "AWS_ACCOUNT"
}

resource "aws_ssoadmin_account_assignment" "operators" {
  instance_arn       = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.secops_operator.arn

  principal_id   = data.aws_identitystore_group.secops_operators.group_id
  principal_type = "GROUP"

  target_id   = var.account_id
  target_type = "AWS_ACCOUNT"
}