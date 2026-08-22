data "aws_iam_policy_document" "ecs_tasks_assume_role" {
  statement {
    sid     = "AllowECSTasksAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values = [
        "arn:${data.aws_partition.current.partition}:ecs:${var.primary_region}:${var.account_id}:*"
      ]
    }
  }
}

resource "aws_iam_role" "ecs_task_execution_roles" {
  for_each = var.ecs_iam_services

  name               = "${var.name_prefix}-${each.key}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json

  tags = {
    Name        = "${var.name_prefix}-${each.key}-ecs-execution"
    Environment = var.environment
    Terraform   = "true"
  }
}

resource "aws_iam_role" "ecs_task_roles" {
  for_each = var.ecs_iam_services

  name               = "${var.name_prefix}-${each.key}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json

  tags = {
    Name        = "${var.name_prefix}-${each.key}-ecs-task"
    Environment = var.environment
    Terraform   = "true"
  }
}

data "aws_iam_policy_document" "ecs_task_execution_policies" {
  statement {
    sid       = "AllowECRAuthorization"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "AllowECRImagePulls"
    effect = "Allow"

    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
    ]

    resources = each.value.ecr_repository_arns
  }

  statement {
    sid    = "AllowCloudWatchLogWrites"
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]

    resources = [
      for arn in each.value.log_group_arns : "${arn}:*"
    ]
  }
}

resource "aws_iam_role_policy" "ecs_task_exeuction_policies" {
  for_each = var.ecs_iam_services

  name = "${var.name_prefix}-${each.key}-ecs-execution"
  role = aws_iam_role.ecs_task_execution_roles[each.key].id
  policy = data.aws_iam_policy_document.ecs_task_execution_policies[each.key].json
}