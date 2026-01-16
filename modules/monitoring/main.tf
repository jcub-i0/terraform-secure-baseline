# SNS
## SNS RESOURCES FOR CONFIG
### CONFIG DOES NOT HAVE AN SNS SUBSCRIPTION (YET)
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

## SNS RESOURCES FOR SECURITY
### SECURITY SNS TOPIC
resource "aws_sns_topic" "security" {
  name = "security-notifications"
  kms_master_key_id = var.logs_kms_key_arn

  tags = {
    Name = "CloudtrailNotifications"
    Terraform = "true"
  }
}

### SECURITY SNS TOPIC POLICY
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