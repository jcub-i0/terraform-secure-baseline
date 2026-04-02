# GITHUB OIDC RESOURCES

## Build subject strings dynamically
locals {
  github_branch_subjects = [
    for branch in var.github_branches :
    "repo:${var.github_owner}/${var.github_repo}:ref:refs/heads/${branch}"
  ]

  github_pr_subject = "repo:${var.github_owner}/${var.github_repo}:pull_request"

  github_oidc_subjects = concat(
    local.github_branch_subjects,
    var.github_allow_pull_requests ? [local.github_pr_subject] : []
  )
}

data "aws_iam_policy_document" "github_oidc_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.github_oidc_subjects
    }
  }
}

resource "aws_iam_role" "github_plan" {
  name               = "${var.name_prefix}-github-plan-role"
  assume_role_policy = data.aws_iam_policy_document.github_oidc_assume_role.json
}

resource "aws_iam_policy" "github_plan" {
  name = "${var.name_prefix}-github-plan-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid    = "TerraformStateBucketList"
          Effect = "Allow"
          Action = [
            "s3:ListBucket"
          ]
          Resource = [
            var.tf_state_bucket_arn
          ]
        },
        {
          Sid    = "TerraformStateObjectAccess"
          Effect = "Allow"
          Action = [
            "s3:GetObject",
            "s3:PutObject",
            "s3:DeleteObject"
          ]
          Resource = [
            "${var.tf_state_bucket_arn}/*"
          ]
        },
        {
          Sid    = "SecretsManagerRead"
          Effect = "Allow"
          Action = [
            "secretsmanager:GetSecretValue"
          ]
          Resource = [
            "arn:aws:secretsmanager:${var.primary_region}:${var.account_id}:secret:${var.name_prefix}/*"
          ]
        },
        {
          Sid = "SecretsManagerRandomPassword"
          Effect = "Allow"
          Action = [
            "secretsmanager:GetRandomPassword"
          ]
          Resource = "*"
        },
      ],
      var.tf_state_lock_table_arn != null ? [
        {
          Sid    = "TerraformStateLockAccess"
          Effect = "Allow"
          Action = [
            "dynamodb:GetItem",
            "dynamodb:PutItem",
            "dynamodb:DeleteItem",
            "dynamodb:UpdateItem"
          ]
          Resource = var.tf_state_lock_table_arn
        }
      ] : []
    )
  })
}

resource "aws_iam_role_policy_attachment" "github_plan_attach" {
  role       = aws_iam_role.github_plan.name
  policy_arn = aws_iam_policy.github_plan.arn
}

resource "aws_iam_role_policy_attachment" "readonly_github_plan_attach" {
  role       = aws_iam_role.github_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}