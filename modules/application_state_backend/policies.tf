locals {
  # Account delegation plus exact role conditions avoids depending on creation
  # of the application roles in the separate account-bootstrap state.
  # Matching roles still need their own identity-policy permissions.
  key_policy = {
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DelegateAdministrationToPlatformRoles"
        Effect    = "Allow"
        Principal = { AWS = local.account_arn }
        Action    = "kms:*"
        Resource  = "*"
        Condition = { ArnEquals = { "aws:PrincipalArn" = local.admin_roles } }
      },
      {
        Sid       = "DelegateBackendEncryptionThroughS3"
        Effect    = "Allow"
        Principal = { AWS = local.account_arn }
        Action    = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey"]
        Resource  = "*"
        Condition = {
          ArnEquals = { "aws:PrincipalArn" = local.backend_roles }
          StringEquals = {
            "kms:CallerAccount"                = data.aws_caller_identity.current.account_id
            "kms:ViaService"                   = "s3.${data.aws_region.current.region}.${data.aws_partition.current.dns_suffix}"
            "kms:EncryptionContext:aws:s3:arn" = local.bucket_arn
          }
        }
      },
      {
        Sid       = "DelegateBackendKeyDescription"
        Effect    = "Allow"
        Principal = { AWS = local.account_arn }
        Action    = "kms:DescribeKey"
        Resource  = "*"
        Condition = { ArnEquals = { "aws:PrincipalArn" = local.backend_roles } }
      }
    ]
  }

  # These statements restrict access; they do not grant S3 permissions.
  bucket_policy = {
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [local.bucket_arn, "${local.bucket_arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        Sid       = "DenyUnapprovedBackendPrincipals"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [local.bucket_arn, "${local.bucket_arn}/*"]
        Condition = { ArnNotEqualsIfExists = { "aws:PrincipalArn" = local.all_roles } }
      },
      {
        Sid       = "DenyNonBackendOperationsExceptAdministrators"
        Effect    = "Deny"
        Principal = "*"
        NotAction = [
          "s3:ListBucket", "s3:GetBucketLocation",
          "s3:GetObject", "s3:PutObject", "s3:DeleteObject"
        ]
        Resource  = [local.bucket_arn, "${local.bucket_arn}/*"]
        Condition = { ArnNotEqualsIfExists = { "aws:PrincipalArn" = local.admin_roles } }
      },
      {
        Sid         = "DenyOtherObjectsExceptAdministrators"
        Effect      = "Deny"
        Principal   = "*"
        Action      = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        NotResource = [local.state_object_arn, local.lock_object_arn]
        Condition   = { ArnNotEqualsIfExists = { "aws:PrincipalArn" = local.admin_roles } }
      },
      {
        Sid       = "DenyStateWritesExceptApplyAndAdministrators"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = local.state_object_arn
        Condition = {
          ArnNotEqualsIfExists = {
            "aws:PrincipalArn" = sort(concat(local.admin_roles, [var.access.apply_role_arn]))
          }
        }
      },
      {
        Sid       = "DenyStateDeletionExceptAdministrators"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:DeleteObject"
        Resource  = local.state_object_arn
        Condition = { ArnNotEqualsIfExists = { "aws:PrincipalArn" = local.admin_roles } }
      },
      {
        Sid       = "RequireKmsEncryption"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = "${local.bucket_arn}/*"
        Condition = { StringNotEquals = { "s3:x-amz-server-side-encryption" = "aws:kms" } }
      },
      {
        Sid       = "RequireBackendKey"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = "${local.bucket_arn}/*"
        Condition = { StringNotEquals = { "s3:x-amz-server-side-encryption-aws-kms-key-id" = aws_kms_key.state.arn } }
      }
    ]
  }
}
