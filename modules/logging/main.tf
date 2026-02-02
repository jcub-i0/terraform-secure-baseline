# CLOUDWATCH LOG GROUPS
## CLOUDTRAIL LOG GROUP
resource "aws_cloudwatch_log_group" "cloudtrail" {
  name              = "/aws/cloudtrail/tf-secure-baseline"
  retention_in_days = 90
  kms_key_id        = var.logs_kms_key_arn

  tags = {
    Name      = "CloudTrail-Logs"
    Terraform = "true"
  }
}

## FLOWLOGS LOG GROUP
resource "aws_cloudwatch_log_group" "flowlogs" {
  name = "/aws/flowlogs/tf-secure-baseline"
  retention_in_days = 90
  kms_key_id = var.logs_kms_key_arn

  tags = {
    Name = "FlowLogs"
    Terraform = "true"
  }
}

# CLOUDTRAIL
resource "aws_cloudtrail" "cloudtrail" {
  name                          = "CloudTrail"
  s3_bucket_name                = var.centralized_logs_bucket_id
  s3_key_prefix                 = "CloudTrail"
  kms_key_id                    = var.logs_kms_key_arn
  is_multi_region_trail         = true
  enable_logging                = true
  enable_log_file_validation    = true
  include_global_service_events = true

  cloud_watch_logs_group_arn = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
  cloud_watch_logs_role_arn  = var.cloudtrail_role_arn

  event_selector {
    read_write_type           = "All"
    include_management_events = true
  }

  insight_selector {
    insight_type = "ApiCallRateInsight"
  }

  insight_selector {
    insight_type = "ApiErrorRateInsight"
  }

  depends_on = [aws_cloudwatch_log_group.cloudtrail]

  tags = {
    Name      = "CloudTrail"
    Terraform = "true"
  }
}

# VPC FLOWLOGS
resource "aws_flow_log" "flowlogs" {
  vpc_id = var.vpc_id

  iam_role_arn = var.flowlogs_role_arn
  log_destination_type = "cloud-watch-logs"
  log_destination = aws_cloudwatch_log_group.flowlogs.arn
  traffic_type = "ALL"

  tags = {
    Name = "VPC-Flow-Logs"
    Terraform = "true"
  }
}