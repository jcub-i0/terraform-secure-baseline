# CONFIG IAM RESOURCES

data "aws_iam_policy" "ssm_automation" {
  name = "AmazonSSMAutomationRole"
}

# CONFIG SERVICE-LINKED ROLE
resource "aws_iam_service_linked_role" "config" {
  aws_service_name = "config.amazonaws.com"
}

# CONFIG REMEDIATION TRUST POLICY
data "aws_iam_policy_document" "config_remediation_assume_role" {
  statement {
    sid     = "AllowSSMAssumeRoleFromAccount"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ssm.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }
}

# CONFIG REMEDIATION ROLE
resource "aws_iam_role" "config_remediation" {
  name               = "${var.name_prefix}-ConfigRemediationRole"
  assume_role_policy = data.aws_iam_policy_document.config_remediation_assume_role.json
}

resource "aws_iam_role_policy_attachment" "config_ssm_automation" {
  role       = aws_iam_role.config_remediation.name
  policy_arn = data.aws_iam_policy.ssm_automation.arn
}

## CONFIG REMEDIATION S3 PUBLIC ACCESS BLOCK POLICY
data "aws_iam_policy_document" "s3_public_remediation" {
  statement {
    sid    = "AllowS3PublicAccessBlockRemediation"
    effect = "Allow"

    actions = [
      "s3:GetBucketPublicAccessBlock",
      "s3:PutBucketPublicAccessBlock",
      "s3:GetBucketPolicy",
      "s3:PutBucketPolicy"
    ]

    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "s3_public_remediation" {
  name = "${var.name_prefix}-S3PublicAccessBlockRemediation"
  role = aws_iam_role.config_remediation.id

  policy = data.aws_iam_policy_document.config_remediation_assume_role.json
}