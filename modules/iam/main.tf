# EC2 Roles and Policies
## EC2 Role
resource "aws_iam_role" "ec2_role" {
  name = "ec2_compute_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

## Allow SSM to access EC2 resources
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

## Allow EC2 to push logs and metrics to CloudWatch
resource "aws_iam_role_policy_attachment" "cloudwatch" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

## Create EC2 Instance Profile to attach the ec2_role IAM Role, thus allowing EC2 compute instance(s) to inherit the role
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "tf_sec_baseline_ec2_compute_instance_profile"
  role = aws_iam_role.ec2_role.name
}

# CLOUDTRAIL
## CLOUDTRAIL ROLE
resource "aws_iam_role" "cloudtrail" {
  name = "cloudtrail-cloudwatch-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "cloudtrail.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

##CLOUDTRAIL ROLE POLICY
resource "aws_iam_role_policy" "cloudtrail" {
  role = aws_iam_role.cloudtrail.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ]
      Resource = "${var.cloudtrail_log_group_arn}:*"
    }]
  })
}

# CONFIG SERVICE-LINKED ROLE
resource "aws_iam_service_linked_role" "config" {
  aws_service_name = "config.amazonaws.com"
}

# LAMBDA ROLES
## AWS-MANAGED POLICIES FOR LAMBDA LOGGING & VPC ENI ACCESS
data "aws_iam_policy" "lambda_vpc" {
  arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

data "aws_iam_policy" "lambda_logs" {
  arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

## EC2 ISOLATION LAMBDA
### EC2 ISOLATION LAMBDA EXECUTION ROLE
resource "aws_iam_role" "lambda_ec2_isolation" {
  name = "lambda-ec2-isolation-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

### EC2 ISOLATION IAM POLICY
resource "aws_iam_policy" "lambda_ec2_isolation" {
  name = "lambda-ec2-isolation"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [

      # CUSTOM POLICY FOR EC2 CONTROL
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:ModifyInstanceAttribute",
          "ec2:DescribeSecurityGroups",
          "ec2:CreateTags",
          "ec2:CreateSnapshot"
        ]
        Resource = "*"
      },
      # ALLOW LAMBDA TO CALL SNS
      {
        Effect = "Allow",
        Action = [
          "sns:Publish"
        ],
        Resource = var.security_topic_arn
      },
      # ALLOW LAMBDA TO CALL LOGS KMS KEY
      {
        Effect = "Allow",
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt",
          "kms:Encrypt",
          "kms:DescribeKey"
        ],
        Resource = var.logs_kms_key_arn
      }
    ]
  })
}

### ATTACH EC2 ISOLATION POLICY TO EC2 ISOLATION EXECUTION ROLE
resource "aws_iam_role_policy_attachment" "lambda_ec2_isolation" {
  role       = aws_iam_role.lambda_ec2_isolation.name
  policy_arn = aws_iam_policy.lambda_ec2_isolation.arn
}

### ATTACH AWS-MANAGED POLICY FOR LAMBDA VPC ENI ACCESS
resource "aws_iam_role_policy_attachment" "ec2_isolation_vpc_attach" {
  role       = aws_iam_role.lambda_ec2_isolation.name
  policy_arn = data.aws_iam_policy.lambda_vpc.arn
}

### ATTACH AWS-MANAGED POLICY FOR LAMBDA LOGGING
resource "aws_iam_role_policy_attachment" "ec2_isolation_logs_attach" {
  role       = aws_iam_role.lambda_ec2_isolation.name
  policy_arn = data.aws_iam_policy.lambda_logs.arn
}

## EC2 ROLLBACK LAMBDA
### EC2 ROLLBACK LAMBDA EXECUTION ROLE
resource "aws_iam_role" "lambda_ec2_rollback" {
  name = "lambda-ec2-rollback"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

### EC2 ROLLBACK IAM POLICY
resource "aws_iam_policy" "lambda_ec2_rollback" {
  name = "lambda-rollback-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # CUSTOM POLICY FOR EC2 CONTROL
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:ModifyInstanceAttribute",
          "ec2:DescribeSecurityGroups",
          "ec2:CreateTags"
        ],
        Resource = "*"
      },
      # ALLOW LAMBDA TO CALL SNS
      {
        Effect = "Allow"
        Action = [
          "sns:Publish"
        ],
        Resource = var.security_topic_arn
      },
      # ALLOW LAMBDA TO CALL LOGS KMS KEY
      {
        Effect = "Allow",
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt",
          "kms:Encrypt",
          "kms:DescribeKey"
        ],
        Resource = var.logs_kms_key_arn
      }
    ]
  })
}

### ATTACH EC2 ROLLBACK POLICY TO EC2 ROLLBACK EXECUTION ROLE
resource "aws_iam_role_policy_attachment" "lambda_ec2_rollback" {
  role = aws_iam_role.lambda_ec2_rollback.name
  policy_arn = aws_iam_policy.lambda_ec2_rollback.arn
}

### ATTACH AWS-MANAGED POLICY FOR LAMBDA VPC ENI ACCESS
resource "aws_iam_role_policy_attachment" "ec2_rollback_vpc_attach" {
  role       = aws_iam_role.lambda_ec2_rollback.name
  policy_arn = data.aws_iam_policy.lambda_vpc.arn
}

### ATTACH AWS-MANAGED POLICY FOR LAMBDA LOGGING
resource "aws_iam_role_policy_attachment" "ec2_rollback_logs_attach" {
  role       = aws_iam_role.lambda_ec2_rollback.name
  policy_arn = data.aws_iam_policy.lambda_logs.arn
} 