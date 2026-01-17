# EVENTBRIDGE RESOURCES
## EVENT RULE TO TRIGGER UPON HIGH/CRITICAL SECURITY HUB EC2 FINDINGS
resource "aws_cloudwatch_event_rule" "securityhub_ec2_high_critical" {
  name = "securityhub-ec2-high-critical"
  description = "High/Critical Security Hub EC2 findings"

  event_pattern = jsonencode({
    source = ["aws.securityhub"]
    detail-type = ["Security Hub Findings - Imported"]
    detail = {
        severity = {
            label = ["HIGH", "CRITICAL"]
        }
        resources = {
            type = ["AwsEc2Instance"]
        }
        compliance = {
            status = ["FAILED"]
        }
        workflow = {
            status = ["FAILED"]
        }
    }
  })
}