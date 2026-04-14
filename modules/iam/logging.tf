# CLOUDTRAIL
## CLOUDTRAIL ROLE
resource "aws_iam_role" "cloudtrail" {
  name = "${var.name_prefix}-cloudtrail-cloudwatch-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "cloudtrail.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

##CLOUDTRAIL ROLE POLICY
resource "aws_iam_role_policy" "cloudtrail" {
  role = aws_iam_role.cloudtrail.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ]
      Resource = "${var.cloudtrail_log_group_arn}:*"
    }]
  })
}

# VPC FLOWLOGS
## FLOWLOGS ROLE
resource "aws_iam_role" "flowlogs" {
  name = "${var.name_prefix}-VpcFlowLogsRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "vpc-flow-logs.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = {
    Role = "VPCFlowLogs"
  }
}

### POLICY FOR FLOWLOGS ROLE
resource "aws_iam_role_policy" "flowlogs" {
  name = "${var.name_prefix}-VpcFlowLogsPolicy"
  role = aws_iam_role.flowlogs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ]
      Resource = "${var.flowlogs_log_group_arn}:*"
    }]
  })
}

## CLOUDWATCH TO FIREHOSE ROLE
resource "aws_iam_role" "cw_to_firehose" {
  name = "${var.name_prefix}-CloudWatchLogsToFirehose"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "logs.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

### POLICY FOR CLOUDWATCH TO FIREHOSE ROLE
resource "aws_iam_role_policy" "cw_to_firehose" {
  role = aws_iam_role.cw_to_firehose.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "firehose:PutRecord",
        "firehose:PutRecordBatch"
      ]
      Resource = var.flowlogs_firehose_delivery_stream_arn
    }]
  })
}

# KINESIS FIREHOSE
## FIREHOSE FLOW LOGS ROLE
resource "aws_iam_role" "firehose_flow_logs" {
  name = "${var.name_prefix}-FirehoseFlowLogsRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "firehose.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

## FIREHOSE FLOW LOGS POLICY
resource "aws_iam_role_policy" "firehose_flow_logs" {
  role = aws_iam_role.firehose_flow_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # ALLOW FIREHOSE TO USE CENTRALIZED LOGS S3 BUCKET
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:AbortMultipartUpload",
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          var.centralized_logs_bucket_arn,
          "${var.centralized_logs_bucket_arn}/*"
        ]
      },
      # ALLOW FIREHOSE TO USE LOGS KMS KEY
      {
        Effect = "Allow"
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = var.logs_cmk_arn
      }
    ]
  })
}