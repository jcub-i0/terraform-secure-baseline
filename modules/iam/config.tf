# CONFIG IAM RESOURCES

data "aws_iam_policy" "ssm_automation" {
  name = "AmazonSSMAutomationRole"
}

locals {
  config_service_linked_role_arn = (
    "arn:${data.aws_partition.current.partition}:iam::${var.account_id}:role/aws-service-role/config.amazonaws.com/AWSServiceRoleForConfig"
  )
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
    sid    = "AllowOwnedS3BucketPublicAccessBlockRemediation"
    effect = "Allow"

    actions = [
      "s3:GetBucketPublicAccessBlock",
      "s3:PutBucketPublicAccessBlock"
    ]

    # S3 bucket ARNs do not contain Region/account. Retain coverage across
    # this account's buckets without authorizing cross-account buckets.
    resources = [
      "arn:${data.aws_partition.current.partition}:s3:::*"
    ]

    condition {
      test     = "StringEquals"
      variable = "s3:ResourceAccount"
      values   = [var.account_id]
    }
  }
}

resource "aws_iam_role_policy" "s3_public_remediation" {
  name = "${var.name_prefix}-S3PublicAccessBlockRemediation"
  role = aws_iam_role.config_remediation.id

  policy = data.aws_iam_policy_document.s3_public_remediation.json
}