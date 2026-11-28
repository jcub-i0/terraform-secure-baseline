mock_provider "aws" {
  mock_data "aws_caller_identity" { defaults = { account_id = "123456789012" } }
  mock_data "aws_partition" { defaults = { partition = "aws", dns_suffix = "amazonaws.com" } }
  mock_data "aws_region" { defaults = { region = "us-east-1" } }
}
variables {
  name_prefix = "unit-dev-demo"
  environment = "dev"
  bucket_name = "unit-dev-demo-123456789012-state"
  access = {
    plan_role_arn           = "arn:aws:iam::123456789012:role/application/demo-plan"
    apply_role_arn          = "arn:aws:iam::123456789012:role/application/demo-apply"
    administrator_role_arns = ["arn:aws:iam::123456789012:role/bootstrap-admin"]
  }
}
override_resource {
  target          = aws_kms_key.state
  override_during = plan
  values = {
    arn    = "arn:aws:kms:us-east-1:123456789012:key/11111111-1111-1111-1111-111111111111"
    key_id = "11111111-1111-1111-1111-111111111111"
  }
}
run "encrypted_versioned_backend_contract" {
  command = plan
  assert {
    condition = (
      aws_s3_bucket.state.force_destroy == false &&
      aws_s3_bucket_public_access_block.state.block_public_acls &&
      aws_s3_bucket_public_access_block.state.block_public_policy &&
      aws_s3_bucket_public_access_block.state.ignore_public_acls &&
      aws_s3_bucket_public_access_block.state.restrict_public_buckets &&
      one(aws_s3_bucket_ownership_controls.state.rule).object_ownership == "BucketOwnerEnforced" &&
      one(aws_s3_bucket_versioning.state.versioning_configuration).status == "Enabled" &&
      one(aws_s3_bucket_server_side_encryption_configuration.state.rule).bucket_key_enabled &&
      one(one(aws_s3_bucket_server_side_encryption_configuration.state.rule).apply_server_side_encryption_by_default).kms_master_key_id == aws_kms_key.state.arn &&
      aws_kms_key.state.enable_key_rotation &&
      aws_kms_key.state.deletion_window_in_days == 30 &&
      output.backend.key == "application.tfstate" &&
      output.backend.kms_key_id == aws_kms_key.state.arn &&
      output.backend.encrypt && output.backend.use_lockfile &&
      output.iam_resources.lock_object_arn == "arn:aws:s3:::unit-dev-demo-123456789012-state/application.tfstate.tflock"
    )
    error_message = "Backend must retain encrypted/versioned state and publish the exact key and native lock configuration."
  }
}
run "bucket_access_separates_plan_apply_and_administration" {
  command = plan
  assert {
    condition = (
      alltrue([for s in jsondecode(aws_s3_bucket_policy.state.policy).Statement : s.Effect == "Deny"]) &&
      toset(one([for s in jsondecode(aws_s3_bucket_policy.state.policy).Statement : s if s.Sid == "DenyUnapprovedBackendPrincipals"]).Condition.ArnNotEqualsIfExists["aws:PrincipalArn"]) == toset(concat([var.access.plan_role_arn, var.access.apply_role_arn], tolist(var.access.administrator_role_arns))) &&
      toset(one([for s in jsondecode(aws_s3_bucket_policy.state.policy).Statement : s if s.Sid == "DenyStateWritesExceptApplyAndAdministrators"]).Condition.ArnNotEqualsIfExists["aws:PrincipalArn"]) == toset(concat([var.access.apply_role_arn], tolist(var.access.administrator_role_arns))) &&
      one([for s in jsondecode(aws_s3_bucket_policy.state.policy).Statement : s if s.Sid == "DenyStateDeletionExceptAdministrators"]).Resource == output.iam_resources.state_object_arn &&
      toset(one([for s in jsondecode(aws_s3_bucket_policy.state.policy).Statement : s if s.Sid == "DenyNonBackendOperationsExceptAdministrators"]).NotAction) == toset(["s3:ListBucket", "s3:GetBucketLocation", "s3:GetObject", "s3:PutObject", "s3:DeleteObject"]) &&
      toset(one([for s in jsondecode(aws_s3_bucket_policy.state.policy).Statement : s if s.Sid == "DenyNonBackendOperationsExceptAdministrators"]).Condition.ArnNotEqualsIfExists["aws:PrincipalArn"]) == toset(var.access.administrator_role_arns) &&
      toset(one([for s in jsondecode(aws_s3_bucket_policy.state.policy).Statement : s if s.Sid == "DenyOtherObjectsExceptAdministrators"]).NotResource) == toset([output.iam_resources.state_object_arn, output.iam_resources.lock_object_arn]) &&
      one([for s in jsondecode(aws_s3_bucket_policy.state.policy).Statement : s if s.Sid == "RequireBackendKey"]).Condition.StringNotEquals["s3:x-amz-server-side-encryption-aws-kms-key-id"] == output.backend.kms_key_id &&
      one([for s in jsondecode(aws_s3_bucket_policy.state.policy).Statement : s if s.Sid == "RequireKmsEncryption"]).Condition.StringNotEquals["s3:x-amz-server-side-encryption"] == "aws:kms" &&
      one([for s in jsondecode(aws_s3_bucket_policy.state.policy).Statement : s if s.Sid == "DenyInsecureTransport"]).Condition.Bool["aws:SecureTransport"] == "false"
    )
    error_message = "Backend policy must preserve role separation, TLS, exact state/lock scope, encryption, and protected history/administration."
  }
}
run "key_delegation_is_bound_to_roles_and_bucket" {
  command = plan
  assert {
    condition = (
      length(jsondecode(aws_kms_key.state.policy).Statement) == 3 &&
      alltrue([for s in jsondecode(aws_kms_key.state.policy).Statement : s.Principal.AWS == "arn:aws:iam::123456789012:root"]) &&
      toset(one([for s in jsondecode(aws_kms_key.state.policy).Statement : s if s.Sid == "DelegateAdministrationToPlatformRoles"]).Condition.ArnEquals["aws:PrincipalArn"]) == toset(var.access.administrator_role_arns) &&
      toset(one([for s in jsondecode(aws_kms_key.state.policy).Statement : s if s.Sid == "DelegateBackendEncryptionThroughS3"]).Condition.ArnEquals["aws:PrincipalArn"]) == toset([var.access.plan_role_arn, var.access.apply_role_arn]) &&
      one([for s in jsondecode(aws_kms_key.state.policy).Statement : s if s.Sid == "DelegateBackendEncryptionThroughS3"]).Condition.StringEquals["kms:ViaService"] == "s3.us-east-1.amazonaws.com" &&
      one([for s in jsondecode(aws_kms_key.state.policy).Statement : s if s.Sid == "DelegateBackendEncryptionThroughS3"]).Condition.StringEquals["kms:EncryptionContext:aws:s3:arn"] == output.iam_resources.bucket_arn &&
      toset(one([for s in jsondecode(aws_kms_key.state.policy).Statement : s if s.Sid == "DelegateBackendEncryptionThroughS3"]).Action) == toset(["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey"])
    )
    error_message = "Key policy must delegate only exact roles and constrain backend cryptography to this bucket through regional S3."
  }
}
run "reject_wildcard_role" {
  command = plan
  variables {
    access = {
      plan_role_arn           = "arn:aws:iam::123456789012:role/application/*"
      apply_role_arn          = "arn:aws:iam::123456789012:role/application/demo-apply"
      administrator_role_arns = ["arn:aws:iam::123456789012:role/bootstrap-admin"]
    }
  }
  expect_failures = [var.access]
}
run "reject_foreign_account" {
  command = plan
  variables {
    access = {
      plan_role_arn           = "arn:aws:iam::999999999999:role/foreign"
      apply_role_arn          = "arn:aws:iam::123456789012:role/application/demo-apply"
      administrator_role_arns = ["arn:aws:iam::123456789012:role/bootstrap-admin"]
    }
  }
  expect_failures = [var.access]
}
run "reject_same_plan_and_apply" {
  command = plan
  variables {
    access = {
      plan_role_arn           = "arn:aws:iam::123456789012:role/application/demo-plan"
      apply_role_arn          = "arn:aws:iam::123456789012:role/application/demo-plan"
      administrator_role_arns = ["arn:aws:iam::123456789012:role/bootstrap-admin"]
    }
  }
  expect_failures = [var.access]
}
run "reject_administrator_overlap" {
  command = plan
  variables {
    access = {
      plan_role_arn           = "arn:aws:iam::123456789012:role/application/demo-plan"
      apply_role_arn          = "arn:aws:iam::123456789012:role/application/demo-apply"
      administrator_role_arns = ["arn:aws:iam::123456789012:role/bootstrap-admin", "arn:aws:iam::123456789012:role/application/demo-apply"]
    }
  }
  expect_failures = [var.access]
}
run "reject_missing_administrators" {
  command = plan
  variables {
    access = {
      plan_role_arn           = "arn:aws:iam::123456789012:role/application/demo-plan"
      apply_role_arn          = "arn:aws:iam::123456789012:role/application/demo-apply"
      administrator_role_arns = []
    }
  }
  expect_failures = [var.access]
}
