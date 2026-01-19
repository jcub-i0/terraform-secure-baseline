# EVENTBRIDGE RESOURCES
## EVENT RULE TO TRIGGER UPON HIGH/CRITICAL SECURITY HUB EC2 FINDINGS
resource "aws_cloudwatch_event_rule" "securityhub_ec2_high_critical" {
  name        = "securityhub-ec2-high-critical"
  description = "High/Critical Security Hub EC2 findings"

  event_pattern = jsonencode({
    source      = ["aws.securityhub"]
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

# EC2 ISOLATION LAMBDA RESOURCES
## EC2 ISOLATION SECURITY GROUP
resource "aws_security_group" "Lambda_EC2_Isolation-SG" {
  name        = "Lambda-EC2-Isolation-SG"
  description = "Security Group for the EC2 Isolation Lambda function"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "AWS API Access"
  }

  tags = {
    Name      = "Lambda-EC2-Isolation-SG"
    Terraform = "true"
  }
}