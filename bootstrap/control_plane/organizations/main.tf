data "aws_caller_identity" "current" {}

resource "aws_organizations_organization" "main" {
  feature_set = "ALL"

  enabled_policy_types = [
    "SECURITYHUB_POLICY",
  ]

  lifecycle {
    prevent_destroy = true

    ignore_changes = [
      aws_service_access_principals,
    ]
  }
}

resource "aws_organizations_organizational_unit" "workloads" {
  name      = "Workloads"
  parent_id = aws_organizations_organization.main.roots[0].id
}

resource "aws_organizations_organizational_unit" "nonprod" {
  name      = "NonProd"
  parent_id = aws_organizations_organizational_unit.workloads.id
}

resource "aws_organizations_organizational_unit" "prod" {
  name      = "Prod"
  parent_id = aws_organizations_organizational_unit.workloads.id
}

resource "aws_organizations_organizational_unit" "security" {
  name      = "Security"
  parent_id = aws_organizations_organization.main.roots[0].id
}

locals {
  security_operations_accounts = [
    for account in aws_organizations_organization.main.accounts :
    account
    if account.name == var.security_operations_account_name
  ]

  security_operations_account_id = try(
    one(local.security_operations_accounts).id,
    null
  )
}

check "security_operations_account" {
  assert {
    condition = (
      !var.enable_securityhub_delegated_administrator ||
      length(local.security_operations_accounts) == 1
    )
    error_message = "Exactly one AWS Organizations account name '${var.security_operations_account_name}' must exist."
  }
}

##########################################
# SECURITY HUB ORGANIZATION INTEGRATION
##########################################

resource "aws_organizations_aws_service_access" "securityhub" {
  count = var.enable_securityhub_delegated_administrator ? 1 : 0

  service_principal = "securityhub.amazonaws.com"
}

resource "aws_securityhub_organization_admin_account" "security_operations" {
  count = var.enable_securityhub_delegated_administrator ? 1 : 0

  admin_account_id = local.security_operations_account_id

  depends_on = [
    aws_organizations_aws_service_access.securityhub
  ]
}

resource "aws_iam_service_linked_role" "securityhub_v2" {
  aws_service_name = "securityhubv2.amazonaws.com"
  description      = "Service-linked role for AWS Security Hub V2 organization management"
}

data "aws_iam_policy_document" "securityhub_v2_organizations_delegation" {
  statement {
    sid    = "SecurityHubV2OrganizationRead"
    effect = "Allow"

    principals {
      type = "AWS"
      identifiers = [
        "arn:aws:iam::${local.security_operations_account_id}:root"
      ]
    }

    actions = [
      "organizations:DescribeOrganization",
      "organizations:DescribeOrganizationalUnit",
      "organizations:DescribeAccount",
      "organizations:ListRoots",
      "organizations:ListOrganizationalUnitsForParent",
      "organizations:ListParents",
      "organizations:ListChildren",
      "organizations:ListAccounts",
      "organizations:ListAccountsForParent",
      "organizations:ListTagsForResource",
    ]

    resources = ["*"]
  }

  statement {
    sid    = "SecurityHubV2PolicyRead"
    effect = "Allow"

    principals {
      type = "AWS"
      identifiers = [
        "arn:aws:iam::${local.security_operations_account_id}:root"
      ]
    }

    actions = [
      "organizations:DescribePolicy",
      "organizations:DescribeEffectivePolicy",
      "organizations:ListPolicies",
      "organizations:ListPoliciesForTarget",
      "organizations:ListTargetsForPolicy",
    ]

    resources = ["*"]

    condition {
      test     = "StringLikeIfExists"
      variable = "organizations:PolicyType"

      values = [
        "SECURITYHUB_POLICY",
      ]
    }
  }

  statement {
    sid    = "SecurityHubV2PolicyManagement"
    effect = "Allow"

    principals {
      type = "AWS"
      identifiers = [
        "arn:aws:iam::${local.security_operations_account_id}:root"
      ]
    }

    actions = [
      "organizations:CreatePolicy",
      "organizations:UpdatePolicy",
      "organizations:DeletePolicy",
      "organizations:AttachPolicy",
      "organizations:DetachPolicy",
    ]

    resources = [
      "arn:aws:organizations::${data.aws_caller_identity.current.account_id}:root/${aws_organizations_organization.main.id}/*",
      "arn:aws:organizations::${data.aws_caller_identity.current.account_id}:ou/${aws_organizations_organization.main.id}/*",
      "arn:aws:organizations::${data.aws_caller_identity.current.account_id}:account/${aws_organizations_organization.main.id}/*",
      "arn:aws:organizations::${data.aws_caller_identity.current.account_id}:policy/${aws_organizations_organization.main.id}/securityhub_policy/*",
    ]

    condition {
      test     = "StringLikeIfExists"
      variable = "organizations:PolicyType"

      values = [
        "SECURITYHUB_POLICY",
      ]
    }
  }

  statement {
    sid    = "SecurityHubV2PolicyTagging"
    effect = "Allow"

    principals {
      type = "AWS"
      identifiers = [
        "arn:aws:iam::${local.security_operations_account_id}:root"
      ]
    }

    actions = [
      "organizations:TagResource",
      "organizations:UntagResource",
    ]

    resources = [
      "arn:aws:organizations::${data.aws_caller_identity.current.account_id}:policy/${aws_organizations_organization.main.id}/securityhub_policy/*",
    ]
  }
}

resource "aws_organizations_resource_policy" "securityhub_v2" {
  content = data.aws_iam_policy_document.securityhub_v2_organizations_delegation.json

  depends_on = [
    aws_iam_service_linked_role.securityhub_v2,
    aws_organizations_organization.main,
    aws_securityhub_organization_admin_account.security_operations,
  ]
}

##########################################
# GUARDDUTY ORGANIZATION INTEGRATION
##########################################

resource "aws_organizations_aws_service_access" "guardduty" {
  count = var.enable_guardduty_delegated_administrator ? 1 : 0

  service_principal = "guardduty.amazonaws.com"
}

resource "aws_organizations_aws_service_access" "guardduty_malware_protection" {
  service_principal = "malware-protection.guardduty.amazonaws.com"
}

resource "aws_guardduty_organization_admin_account" "security_operations" {
  count = var.enable_guardduty_delegated_administrator ? 1 : 0

  admin_account_id = local.security_operations_account_id

  depends_on = [
    aws_organizations_aws_service_access.guardduty
  ]
}