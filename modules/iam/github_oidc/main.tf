###########################################
# GITHUB OIDC MODULE (CHILD MODULE OF IAM)
###########################################

## Build subject strings dynamically
locals {

  plan_branch_subjects_github = [
    for branch in var.branches_plan_github :
    "repo:${var.owner_github}/${var.repo_github}:ref:refs/heads/${branch}"
  ]

  github_pr_subject = "repo:${var.owner_github}/${var.repo_github}:pull_request"

  plan_oidc_subjects_github = concat(
    local.plan_branch_subjects_github,
    var.allow_pull_requests_plan_github ? [local.github_pr_subject] : []
  )

}

locals {
  apply_branch_subjects_github = [
    for branch in var.branches_apply_github :
    "repo:${var.owner_github}/${var.repo_github}:ref:refs/heads/${branch}"
  ]

  apply_environment_subjects_github = var.environment_apply_github != null ? [
    "repo:${var.owner_github}/${var.repo_github}:environment:${var.environment_apply_github}"
  ] : []

  apply_oidc_subjects_github = (
    var.environment_apply_github != null ?
    local.apply_environment_subjects_github :
    local.apply_branch_subjects_github
  )
}

# GitHub-Plan resources
## GitHub-Plan trust policy
data "aws_iam_policy_document" "plan_oidc_assume_role" {
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
      values   = local.plan_oidc_subjects_github
    }
  }
}

resource "aws_iam_role" "github_plan" {
  name               = "${var.name_prefix}-github-plan-role"
  assume_role_policy = data.aws_iam_policy_document.plan_oidc_assume_role.json
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
          Sid    = "SecretsManagerRandomPassword"
          Effect = "Allow"
          Action = [
            "secretsmanager:GetRandomPassword"
          ]
          Resource = "*"
        },
        {
          Sid    = "SecretsManagerKmsDecrypt"
          Effect = "Allow"
          Action = [
            "kms:Decrypt",
            "kms:DescribeKey"
          ]
          Resource = [
            var.secrets_manager_cmk_arn
          ]
        },
        {
          Sid    = "LambdaKmsDecrypt"
          Effect = "Allow"
          Action = [
            "kms:Decrypt",
            "kms:DescribeKey"
          ]
          Resource = [
            var.lambda_cmk_arn
          ]
        }
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
      ] : [],
      var.tf_state_bucket_cmk_arn != null ? [
        {
          Sid    = "TerraformStateBucketKmsAccess"
          Effect = "Allow"
          Action = [
            "kms:Decrypt",
            "kms:DescribeKey"
          ]
          Resource = [
            var.tf_state_bucket_cmk_arn
          ]
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

# GitHub-Apply resources
## GitHub-Apply trust policy
data "aws_iam_policy_document" "apply_oidc_assume_role" {
  count = var.enable_apply_role_github ? 1 : 0

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
      values   = local.apply_oidc_subjects_github
    }
  }
}

## GitHub-Apply role
resource "aws_iam_role" "github_apply" {
  count = var.enable_apply_role_github ? 1 : 0

  name               = "${var.name_prefix}-github-apply-role"
  assume_role_policy = data.aws_iam_policy_document.apply_oidc_assume_role[0].json
}

## GitHub-Apply role policy
resource "aws_iam_policy" "github_apply" {
  count = var.enable_apply_role_github ? 1 : 0

  name = "${var.name_prefix}-github-apply-policy"

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
          Sid    = "SecretsManagerRandomPassword"
          Effect = "Allow"
          Action = [
            "secretsmanager:GetRandomPassword"
          ]
          Resource = "*"
        },
        {
          Sid    = "SecretsManagerKmsDecrypt"
          Effect = "Allow"
          Action = [
            "kms:Decrypt",
            "kms:DescribeKey"
          ]
          Resource = [
            var.secrets_manager_cmk_arn
          ]
        },
        {
          Sid    = "LambdaKmsDecrypt"
          Effect = "Allow"
          Action = [
            "kms:Decrypt",
            "kms:DescribeKey"
          ]
          Resource = [
            var.lambda_cmk_arn
          ]
        }
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
      ] : [],
      var.tf_state_bucket_cmk_arn != null ? [
        {
          Sid    = "TerraformStateBucketKmsAccess"
          Effect = "Allow"
          Action = [
            "kms:Decrypt",
            "kms:DescribeKey"
          ]
          Resource = [
            var.tf_state_bucket_cmk_arn
          ]
        }
      ] : []
    )
  })
}

resource "aws_iam_role_policy_attachment" "github_apply_attach" {
  count = var.enable_apply_role_github ? 1 : 0

  role       = aws_iam_role.github_apply[0].name
  policy_arn = aws_iam_policy.github_apply[0].arn
}

## AWS-managed AdministratorAccessRole policy
resource "aws_iam_role_policy_attachment" "admin_github_apply_attach" {
  count = var.enable_apply_role_github ? 1 : 0

  role       = aws_iam_role.github_apply[0].name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}