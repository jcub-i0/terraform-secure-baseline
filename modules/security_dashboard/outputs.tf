output "securityhub_insight_arns" {
  description = "ARNs of Security Hub custom insights"
  value = {
    high_critical     = aws_securityhub_insight.high_critical.arn
    guardduty         = aws_securityhub_insight.guardduty_active.arn
    inspector         = aws_securityhub_insight.inspector_active.arn
    ec2_findings      = aws_securityhub_insight.ec2_findings.arn
    ec2_high_critical = aws_securityhub_insight.ec2_high_critical.arn
    failed_controls   = aws_securityhub_insight.failed_controls.arn
  }
}