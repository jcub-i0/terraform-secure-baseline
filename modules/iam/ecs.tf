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

# Configured managed policies are attached only to application task roles.
# The service and its policy ARNs must be known during Terraform planning.
locals {
  ecs_task_managed_policy_attachments = {
    for attachment in flatten([
      for service_name, service in var.ecs_iam_services : [
        for policy_arn in service.task_role_managed_policy_arns : {
          key          = "${service_name}|${policy_arn}"
          service_name = service_name
          policy_arn   = policy_arn
        }
      ]
    ]) : attachment.key => attachment
  }
}

resource "aws_iam_role_policy_attachment" "ecs_task_managed_policies" {
  for_each = local.ecs_task_managed_policy_attachments

  role       = aws_iam_role.ecs_task_roles[each.value.service_name].name
  policy_arn = each.value.policy_arn

  lifecycle {
    precondition {
      condition = can(regex(
        "^arn:${data.aws_partition.current.partition}:iam::(${var.account_id}|aws):policy/[A-Za-z0-9+=,.@_/-]+$",
        each.value.policy_arn
      ))
      error_message = "Task-role managed policies must be AWS-managed or same-account customer-managed policies in the current partition."
    }
  }
}

data "aws_iam_policy_document" "ecs_task_execution_policies" {
  for_each = var.ecs_iam_services

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

  dynamic "statement" {
    for_each = length(each.value.execution_secret_arns) > 0 ? [1] : []

    content {
      sid    = "AllowSecretsManagerRead"
      effect = "Allow"

      actions = [
        "secretsmanager:GetSecretValue",
      ]

      resources = each.value.execution_secret_arns
    }
  }

  dynamic "statement" {
    for_each = length(each.value.execution_ssm_parameter_arns) > 0 ? [1] : []

    content {
      sid    = "AllowSSMParameterRead"
      effect = "Allow"

      actions = [
        "ssm:GetParameters",
      ]

      resources = each.value.execution_ssm_parameter_arns
    }
  }

  dynamic "statement" {
    for_each = length(each.value.task_execution_kms_key_arns) > 0 ? [1] : []

    content {
      sid    = "AllowExecutionKMSDecrypt"
      effect = "Allow"

      actions = [
        "kms:Decrypt",
      ]

      resources = each.value.task_execution_kms_key_arns
    }
  }

  dynamic "statement" {
    for_each = length(each.value.guardduty_agent_ecr_repository_arns) > 0 ? [1] : []

    content {
      sid    = "AllowGuardDutyAgentImagePulls"
      effect = "Allow"

      actions = [
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
      ]

      resources = each.value.guardduty_agent_ecr_repository_arns
    }
  }
}

resource "aws_iam_role_policy" "ecs_task_execution_policies" {
  for_each = var.ecs_iam_services

  name   = "${var.name_prefix}-${each.key}-ecs-execution"
  role   = aws_iam_role.ecs_task_execution_roles[each.key].id
  policy = data.aws_iam_policy_document.ecs_task_execution_policies[each.key].json
}