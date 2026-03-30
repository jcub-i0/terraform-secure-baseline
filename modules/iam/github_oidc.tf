# GITHUB OIDC RESOURCES

## Build subject strings dynamically
locals {
  github_branch_subjects = [
    for branch in var.github_branches :
    "repo:${var.github_owner}/${var.github_repo}:ref:refs/heads/${branch}"
  ]

  github_pr_subject = "repo:${var.github_owner}/${var.github_repo}/:pull_request"
}

resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = [
    "sts.amazonaws.com"
  ]

  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1"
  ]
}

data "aws_iam_policy_document" "github_oidc_assume_role" {
  statement {
    effect = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github]
    }

    condition {
      test = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values = ["sts.amazonaws.com"]
    }

    condition {
      test = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        local.github_branch_subjects
      ]
    }
  }
}

resource "aws_iam_role" "github_plan" {
  name = "${var.name_prefix}-github-plan-role"
  assume_role_policy = data.aws_iam_policy_document.github_oidc_assume_role.json
}