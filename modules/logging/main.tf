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

# KINESIS FIREHOSE FOR VPC FLOWLOGS
## FLOWLOGS FIREHOSE DELIVERITY STREAM
resource "aws_kinesis_firehose_delivery_stream" "flowlogs" {
  name = "vpc-flow-logs-to-s3"
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn = var.firehose_flow_logs_role_arn
    bucket_arn = var.centralized_logs_bucket_arn

    prefix = "vpc-flow-logs/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/hour=!{timestamp:HH}/"
    error_output_prefix = "errors/vpc-flow-logs/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/hour=!{timestamp:HH}/!{firehose:error-output-type}/"

    buffering_interval = 300
    buffering_size = 5

    compression_format = "GZIP"
  }
}

## CLOUDWATCH LOGS SUBSCRIPTION FILTER FOR FLOWLOGS FIREHOSE
resource "aws_cloudwatch_log_subscription_filter" "flowlogs" {
  name = "vpc-flow-logs-to-firehose"
  log_group_name = aws_cloudwatch_log_group.flowlogs.name
  destination_arn = aws_kinesis_firehose_delivery_stream.flowlogs.arn
  role_arn = var.cw_to_firehose_role_arn
  filter_pattern = ""
}