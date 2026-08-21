data "aws_iam_policy_document" "ecs_tasks_assume_role" {
  statement {
    sid = "AllowECSTasksAssumeRole"
    effect = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    condition {
      test = "StringEquals"
      variable = "aws:SourceAccount"
      values = [var.account_id]
    }

    condition {
      test = "ArnLike"
      variable = "aws:SourceArn"
      values = [
        "arn:${data.aws_partition.current.partition}:ecs:${var.primary_region}:${var.account_id}:*"
      ]
    }
  }
}