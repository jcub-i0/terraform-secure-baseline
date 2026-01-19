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

# CONFIG
## CONFIG ROLE
resource "aws_iam_role" "config" {
  name = "aws-config-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
        Effect = "Allow"
        Principal = {
            Service = "config.amazonaws.com"
        }
        Action = "sts:AssumeRole"
    }]
  })
}

## CONFIG ROLE POLICY
resource "aws_iam_role_policy_attachment" "config" {
  role = aws_iam_role.config.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

# LAMBDA
# EC2 ISOLATION LAMBDA EXECUTION ROLE
resource "aws_iam_role" "lambda_ec2_isolation" {
  name = "lambda_ec2_isolation"

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