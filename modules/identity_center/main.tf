# IAM IDENTITY CENTER (SSO) RESOURCES

# Discover the existing Identity Center instance
data "aws_partition" "current" {}

data "aws_ssoadmin_instances" "this" {}

locals {
  instance_arn      = tolist(data.aws_ssoadmin_instances.this.arns)[0]
  identity_store_id = tolist(data.aws_ssoadmin_instances.this.identity_store_ids)[0]
}

# Baseline-managed Identity Center groups
resource "aws_identitystore_group" "secops_operators" {
  count = var.enable_secops_operator ? 1 : 0

  identity_store_id = local.identity_store_id
  display_name      = var.secops_operator_group_name
  description       = "SecOps-Operators Identity Center Group"
}

resource "aws_identitystore_group" "secops_administrators" {
  count = var.enable_secops_administrator ? 1 : 0

  identity_store_id = local.identity_store_id
  display_name      = var.secops_administrator_group_name
  description       = "SecOps-Administrators Identity Center group"
}

# Permission sets
resource "aws_ssoadmin_permission_set" "secops_operator" {
  count = var.enable_secops_operator ? 1 : 0

  name             = "SecOps-Operator-${var.environment}"
  description      = "Privileged operational rollback access"
  instance_arn     = local.instance_arn
  session_duration = "PT2H"
}

resource "aws_ssoadmin_permission_set" "secops_administrator" {
  count = var.enable_secops_administrator ? 1 : 0

  name             = "SecOps-Administrator-${var.environment}"
  description      = "Administrative access for the central security account"
  instance_arn     = local.instance_arn
  session_duration = "PT2H"
}

# Administrator policy attachment
resource "aws_ssoadmin_managed_policy_attachment" "secops_administrator_access" {
  count = var.enable_secops_administrator ? 1 : 0

  instance_arn       = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.secops_administrator[0].arn
  managed_policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AdministratorAccess"
}

# Operator inline event-publishing policy
resource "aws_ssoadmin_permission_set_inline_policy" "secops_operator_inline" {
  count = var.enable_secops_operator ? 1 : 0

  instance_arn       = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.secops_operator[0].arn

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

# Account assignments
resource "aws_ssoadmin_account_assignment" "operators" {
  count = var.enable_secops_operator ? 1 : 0

  instance_arn       = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.secops_operator[0].arn

  principal_id   = aws_identitystore_group.secops_operators[0].group_id
  principal_type = "GROUP"

  target_id   = var.account_id
  target_type = "AWS_ACCOUNT"

  depends_on = [
    aws_ssoadmin_permission_set_inline_policy.secops_operator_inline
  ]
}

resource "aws_ssoadmin_account_assignment" "administrators" {
  count = var.enable_secops_administrator ? 1 : 0

  instance_arn       = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.secops_administrator[0].arn

  principal_id   = aws_identitystore_group.secops_administrators[0].group_id
  principal_type = "GROUP"

  target_id   = var.account_id
  target_type = "AWS_ACCOUNT"

  depends_on = [
    aws_ssoadmin_managed_policy_attachment.secops_administrator_access
  ]
}
