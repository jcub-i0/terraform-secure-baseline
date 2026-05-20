# CLOUDTRAIL

## CLOUDTRAIL TRUST POLICY
data "aws_iam_policy_document" "cloudtrail_assume_role" {
  statement {
    sid     = "AllowCloudTrailAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
  }
}

## CLOUDTRAIL ROLE
resource "aws_iam_role" "cloudtrail" {
  name               = "${var.name_prefix}-cloudtrail-cloudwatch-role"
  assume_role_policy = data.aws_iam_policy_document.cloudtrail_assume_role.json
}

## CLOUDTRAIL ROLE POLICY
data "aws_iam_policy_document" "cloudtrail" {
  statement {
    sid    = "AllowCloudTrailWriteToCloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]

    resources = ["${var.cloudtrail_log_group_arn}:*"]
  }
}

resource "aws_iam_role_policy" "cloudtrail" {
  role   = aws_iam_role.cloudtrail.id
  policy = data.aws_iam_policy_document.cloudtrail.json
}

# VPC FLOWLOGS

## FLOWLOGS TRUST POLICY
data "aws_iam_policy_document" "flowlogs_assume_role" {
  statement {
    sid     = "AllowVPCFlowLogsAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

## FLOWLOGS ROLE
resource "aws_iam_role" "flowlogs" {
  name               = "${var.name_prefix}-VpcFlowLogsRole"
  assume_role_policy = data.aws_iam_policy_document.flowlogs_assume_role.json

  tags = {
    Role = "VPCFlowLogs"
  }
}

## FLOWLOGS ROLE POLICY
data "aws_iam_policy_document" "flowlogs" {
  statement {
    sid    = "AllowFlowLogsWriteToCloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams"
    ]

    resources = ["${var.flowlogs_log_group_arn}:*"]
  }
}

resource "aws_iam_role_policy" "flowlogs" {
  name   = "${var.name_prefix}-VpcFlowLogsPolicy"
  role   = aws_iam_role.flowlogs.id
  policy = data.aws_iam_policy_document.flowlogs.json
}

# CLOUDWATCH TO FIREHOSE
## CLOUDWATCH TO FIREHOSE TRUST POLICY
data "aws_iam_policy_document" "cw_to_firehose_assume_role" {
  statement {
    sid     = "AllowCloudWatchLogsAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["logs.amazonaws.com"]
    }
  }
}

## CLOUDWATCH TO FIREHOSE ROLE
resource "aws_iam_role" "cw_to_firehose" {
  name               = "${var.name_prefix}-CloudWatchLogsToFirehose"
  assume_role_policy = data.aws_iam_policy_document.cw_to_firehose_assume_role.json
}

## POLICY FOR CLOUDWATCH TO FIREHOSE ROLE
data "aws_iam_policy_document" "cw_to_firehose" {
  statement {
    sid    = "AllowCloudWatchLogsWriteToFirehose"
    effect = "Allow"
    actions = [
      "firehose:PutRecord",
      "firehose:PutRecordBatch"
    ]

    resources = [var.flowlogs_firehose_delivery_stream_arn]
  }
}

resource "aws_iam_role_policy" "cw_to_firehose" {
  role   = aws_iam_role.cw_to_firehose.id
  policy = data.aws_iam_policy_document.cw_to_firehose.json
}

# KINESIS FIREHOSE
## KINESIS FIREHOSE TRUST POLICY
data "aws_iam_policy_document" "firehose_flow_logs_assume_role" {
  statement {
    sid     = "AllowFirehoseAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["firehose.amazonaws.com"]
    }
  }
}

## FIREHOSE FLOW LOGS ROLE
resource "aws_iam_role" "firehose_flow_logs" {
  name               = "${var.name_prefix}-FirehoseFlowLogsRole"
  assume_role_policy = data.aws_iam_policy_document.firehose_flow_logs_assume_role.json
}

## FIREHOSE FLOW LOGS POLICY
data "aws_iam_policy_document" "firehose_flow_logs" {
  statement {
    sid    = "AllowFirehoseWriteToCentralizedLogsS3"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:AbortMultipartUpload",
      "s3:ListBucket",
      "s3:GetBucketLocation"
    ]

    resources = [
      var.centralized_logs_bucket_arn,
      "${var.centralized_logs_bucket_arn}/*"
    ]
  }

  statement {
    sid    = "AllowFirehoseUseLogsKMSKey"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:GenerateDataKey*",
      "kms:DescribeKey"
    ]

    resources = [var.logs_cmk_arn]
  }
}

resource "aws_iam_role_policy" "firehose_flow_logs" {
  role   = aws_iam_role.firehose_flow_logs.id
  policy = data.aws_iam_policy_document.firehose_flow_logs.json
}