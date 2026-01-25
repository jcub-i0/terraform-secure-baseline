# EC2 ISOLATION LAMBDA RESOURCES
## PACKAGE EC2 ISOLATION LAMBDA
data "archive_file" "lambda_ec2_isolation" {
  type        = "zip"
  source_file  = "${path.module}/lambda/ec2_isolation.py"
  output_path = "${path.module}/lambda/ec2_isolation.zip"
}

## EC2 ISOLATION LAMBDA FUNCTION
resource "aws_lambda_function" "ec2_isolation" {
  function_name = "ec2-isolation"
  role          = var.lambda_ec2_isolation_role_arn
  handler       = "ec2_isolation.lambda_handler"
  runtime       = "python3.12"
  filename      = data.archive_file.lambda_ec2_isolation.output_path
  timeout       = 60
  memory_size   = 256
  source_code_hash = data.archive_file.lambda_ec2_isolation.output_base64sha256

  vpc_config {
    subnet_ids         = var.serverless_private_subnet_ids
    security_group_ids = [aws_security_group.lambda_ec2_isolation_sg.id]
  }

  environment {
    variables = {
      QUARANTINE_SG_ID = var.quarantine_sg_id
      SNS_TOPIC_ARN = var.security_topic_arn
    }
  }

  tags = {
    Name      = "EC2-Isolation"
    Terraform = "true"
  }
}

## EVENTBRIDGE RESOURCES
### EVENT RULE TO TRIGGER UPON HIGH/CRITICAL SECURITY HUB EC2 FINDINGS
resource "aws_cloudwatch_event_rule" "securityhub_ec2_high_critical" {
  name        = "securityhub-ec2-high-critical"
  description = "High/Critical Security Hub EC2 findings"

  event_pattern = jsonencode({
    source      = ["aws.securityhub"],
    detail-type = ["Security Hub Findings - Imported"],
    detail = {
        findings = {
            Severity = {
                Label = ["HIGH", "CRITICAL"]
            },
            Resources = {
                Type = ["AwsEc2Instance"]
            },
            Workflow = {
                Status = ["NEW"]
            }
      }
    }
  })
}

### EVENT TARGET FOR HIGH/CRITICAL SECURITY HUB EC2 FINDINGS EVENT RULE
resource "aws_cloudwatch_event_target" "ec2_isolation" {
  rule = aws_cloudwatch_event_rule.securityhub_ec2_high_critical.name
  arn  = aws_lambda_function.ec2_isolation.arn
}

### PERMISSION TO ALLOW EVENTBRIDGE TO INVOKE EC2 ISOLATION LAMBDA
resource "aws_lambda_permission" "allow_eventbridge_ec2_isolation" {
  statement_id  = "AllowExecutionFromEventBridgeEc2Isolation"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ec2_isolation.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.securityhub_ec2_high_critical.arn
}

## EC2 ISOLATION SECURITY GROUP
resource "aws_security_group" "lambda_ec2_isolation_sg" {
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