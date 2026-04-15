# CONFIG IAM RESOURCES

data "aws_iam_policy" "ssm_automation" {
  name = "AmazonSSMAutomationRole"
}

# CONFIG REMEDIATION ROLE
resource "aws_iam_role" "config_remediation" {
  name = "${var.name_prefix}-ConfigRemediationRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ssm.amazonaws.com"
      }
      Action = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = var.account_id
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "config_ssm_automation" {
  role       = aws_iam_role.config_remediation.name
  policy_arn = data.aws_iam_policy.ssm_automation.arn
}

## CONFIG REMEDIATION S3 PUBLIC ACCESS BLOCK POLICY
resource "aws_iam_role_policy" "s3_public_remediation" {
  name = "${var.name_prefix}-S3PublicAccessBlockRemediation"
  role = aws_iam_role.config_remediation.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetBucketPublicAccessBlock",
          "s3:PutBucketPublicAccessBlock",
          "s3:GetBucketPolicy",
          "s3:PutBucketPolicy"
        ]
        Resource = "*"
      }
    ]
  })
}