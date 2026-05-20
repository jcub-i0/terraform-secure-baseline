# EC2 ROLES AND POLICIES

# EC2 TRUST POLICY
data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    sid     = "AllowEC2AssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

## EC2 ROLE
resource "aws_iam_role" "ec2_role" {
  name               = "${var.name_prefix}-ec2_compute_role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
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
  name = "${var.name_prefix}-ec2_compute_instance_profile"
  role = aws_iam_role.ec2_role.name
}