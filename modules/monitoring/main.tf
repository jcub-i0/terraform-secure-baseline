# SNS
## SNS RESOURCES FOR CONFIG
### CONFIG SNS TOPIC
resource "aws_sns_topic" "config" {
  name = "config-notifications"

  tags = {
    Name = "ConfigNotifications"
    Terraform = "true"
  }
}

### CONFIG SNS TOPIC POLICY
resource "aws_sns_topic_policy" "config" {
  arn = aws_sns_topic.config.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
        Effect = "Allow"
        Principal = {
            Service = "config.amazonaws.com"
        }
        Action = "sns:Publish"
        Resource = aws_sns_topic.config.arn
    }]
  })
}