output "cloudtrail_log_group_arn" {
  value = aws_cloudwatch_log_group.cloudtrail.arn
}

output "cloudtrail_logs_group_name" {
  value = aws_cloudwatch_log_group.cloudtrail.name
}

output "flowlogs_firehose_delivery_stream_arn" {
  value = aws_kinesis_firehose_delivery_stream.flowlogs.arn
}

output "flowlogs_log_group_arn" {
  value = aws_cloudwatch_log_group.flowlogs.arn
}

output "cloudtrail_arn" {
  value = aws_cloudtrail.cloudtrail.arn
}