# IAM IDENTITY CENTER (SSO) RESOURCES

##########################################
# IAM IDENTITY CENTER - DISCOVER INSTANCE
##########################################

data "aws_ssoadmin_instances" "this" {}

locals {
  instance_arn = tolist(data.aws_ssoadmin_instances.this.arns)[0]
  identity_store_id = tolist(data.aws_ssoadmin_instances.this.identity_store_ids)[0]
}

##########################################
# GROUP LOOKUPS
##########################################

data "aws_identitystore_group" "analysts" {
  identity_store_id = local.identity_store_id

  alternate_identifier {
    unique_attribute {
      attribute_path = "Displayname"
      attribute_value = var.secops_analyst_group_name
    }
  }
}

data "aws_identitystore_group" "engineers" {
  identity_store_id = local.identity_store_id

  alternate_identifier {
    unique_attribute {
      attribute_path = "DisplayName"
      attribute_value = var.secops_engineer_group_name
    }
  }
}

data "aws_identitystore_group" "operators" {
  identity_store_id = local.identity_store_id

  alternate_identifier {
    unique_attribute {
      attribute_path = "DisplayName"
      attribute_value = var.secops_operator_group_name
    }
  }
}

##########################################
# PERMISSION SETS
##########################################

resource "aws_ssoadmin_permission_set" "analyst" {
  name = "SecOps-Analyst"
  description = "Read-only security visibility for analysts"
  instance_arn = local.instance_arn
  session_duration = "PT4H"
}

resource "aws_ssoadmin_permission_set" "engineer" {
  name = "SecOps-Engineer"
  description = "Security investigation and response access"
  instance_arn = local.instance_arn
  session_duration = "PT4H"
}

resource "aws_ssoadmin_permission_set" "operator" {
  name = "SecOps-Operator"
  description = "Privileged operational rollback access"
  instance_arn = local.identity_store_id
  session_duration = "PT2H"
}

##########################################
# AWS-MANAGED POLICY ATTACHMENTS
##########################################

resource "aws_ssoadmin_managed_policy_attachment" "analyst_security_audit" {
  instance_arn = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.analyst.arn
  managed_policy_arn = "arn:aws:iam::aws:policy/SecurityAudit"
}

resource "aws_ssoadmin_managed_policy_attachment" "analyst_readonly" {
  instance_arn = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.analyst.arn
  managed_policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_ssoadmin_managed_policy_attachment" "engineer_security_audit" {
  instance_arn = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.engineer.arn
  managed_policy_arn = "arn:aws:iam::aws:policy/SecurityAudit"
}