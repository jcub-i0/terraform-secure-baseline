# SNS
## SNS RESOURCES FOR CONFIG
### CONFIG SNS TOPIC
resource "aws_sns_topic" "compliance" {
  name = "compliance-notifications"
  kms_master_key_id = var.logs_kms_key_arn

  tags = {
    Name = "ConfigNotifications"
    Terraform = "true"
  }
}

### CONFIG SNS TOPIC POLICY
resource "aws_sns_topic_policy" "compliance" {
  arn = aws_sns_topic.compliance.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
        Effect = "Allow"
        Principal = {
            Service = "config.amazonaws.com"
        }
        Action = "sns:Publish"
        Resource = aws_sns_topic.compliance.arn
    }]
  })
}

## SNS RESOURCES FOR CLOUDTRAIL
### CLOUDTRAIL SNS TOPIC
resource "aws_sns_topic" "security" {
  name = "security-notifications"

  tags = {
    Name = "CloudtrailNotifications"
    Terraform = "true"
  }
}

### CLOUDTRAIL SNS TOPIC POLICY
resource "aws_sns_topic_policy" "security" {
  arn = aws_sns_topic.security.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
        Effect = "Allow"
        Principal = {
            "Service" = "cloudtrail.amazonaws.com"
        }
        Action = "sns:Publish"
        Resource = aws_sns_topic.security.arn
    }]
  })
}