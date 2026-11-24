# Lambda assumes the broker execution role
data "aws_iam_policy_document" "broker_trust" {
  statement {
    sid     = "AllowLambdaAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "broker_execution" {
  count = length(var.jobs) > 0 ? 1 : 0

  name                 = "${var.name_prefix}-job-broker-execution"
  assume_role_policy   = data.aws_iam_policy_document.broker_trust.json
  permissions_boundary = var.permissions_boundary_arn

  tags = {
    Name        = "${var.name_prefix}-job-broker-execution"
    Environment = var.environment
    Terraform   = "true"
  }
}

# Each launcher trusts only the broker execution role
data "aws_iam_policy_document" "launcher_trust" {
  for_each = var.jobs

  statement {
    sid     = "AllowBrokerAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.broker_execution[0].arn]
    }
  }
}

resource "aws_iam_role" "launcher" {
  for_each = var.jobs

  name                 = "${var.name_prefix}-${each.key}-launcher"
  assume_role_policy   = data.aws_iam_policy_document.launcher_trust[each.key].json
  permissions_boundary = var.permissions_boundary_arn

  tags = {
    Name        = "${var.name_prefix}-${each.key}-launcher"
    Environment = var.environment
    Terraform   = "true"
  }
}

# Broker may assume only the configured launcher roles
data "aws_iam_policy_document" "broker_assume_launchers" {
  count = length(var.jobs) > 0 ? 1 : 0

  statement {
    sid     = "AssumeApprovedLaunchers"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    resources = [
      for role in values(aws_iam_role.launcher) : role.arn
    ]
  }
}

resource "aws_iam_role_policy" "broker_assume_launchers" {
  count = length(var.jobs) > 0 ? 1 : 0

  name   = "${var.name_prefix}-broker-assume-launchers"
  role   = aws_iam_role.broker_execution[0].id
  policy = data.aws_iam_policy_document.broker_assume_launchers[0].json
}

# Each launcher may run only its approved job revision
data "aws_iam_policy_document" "job_launch" {
  for_each = var.jobs

  statement {
    sid       = "RunApprovedTaskRevision"
    effect    = "Allow"
    actions   = ["ecs:RunTask"]
    resources = [each.value.task_definitions_arn]

    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [var.approved_cluster_arn]
    }
  }

  statement {
    sid     = "PassOnlyApprovedJobRoles"
    effect  = "Allow"
    actions = ["iam:PassRole"]

    resources = [
      each.value.execution_role_arn,
      each.value.task_role_arn
    ]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amzonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "job_launch" {
  for_each = var.jobs

  name   = "${var.name_prefix}-${each.key}-job-launch"
  role   = aws_iam_role.launcher[each.key].id
  policy = data.aws_iam_policy_document.job_launch[each.key].json
}