provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

# Offline substitutes for AWS-managed policies used by Lambda roles.
# These are unrelated to the ECS IAM policies under test.

override_data {
  target = data.aws_iam_policy.lambda_vpc

  values = {
    arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
  }
}

override_data {
  target = data.aws_iam_policy.lambda_logs

  values = {
    arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  }
}

override_data {
  target = data.aws_iam_policy.lambda_xray

  values = {
    arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
  }
}

variables {
  cloud_name     = "unit-test"
  name_prefix    = "unit-test-dev"
  environment    = "dev"
  account_id     = "123456789012"
  primary_region = "us-east-1"

  cloudtrail_log_group_arn = "arn:aws:logs:us-east-1:123456789012:log-group:/aws/cloudtrail/test"
  secops_topic_arn         = "arn:aws:sns:us-east-1:123456789012:secops"

  logs_cmk_arn            = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000000"
  secrets_manager_cmk_arn = "arn:aws:kms:us-east-1:123456789012:key/11111111-1111-1111-1111-111111111111"

  centralized_logs_bucket_arn           = "arn:aws:s3:::unit-test-logs"
  flowlogs_firehose_delivery_stream_arn = "arn:aws:firehose:us-east-1:123456789012:deliverystream/test"
  flowlogs_log_group_arn                = "arn:aws:logs:us-east-1:123456789012:log-group:/aws/vpc/flowlogs"

  secops_event_bus_arn               = "arn:aws:events:us-east-1:123456789012:event-bus/secops"
  threat_intel_api_keys_arn          = "arn:aws:secretsmanager:us-east-1:123456789012:secret:api-AbCdEf"
  lambda_ip_enrichment_log_group_arn = "arn:aws:logs:us-east-1:123456789012:log-group:/aws/lambda/enrichment"

  break_glass_trusted_principal_arns = [
    "arn:aws:iam::123456789012:role/test-admin"
  ]

  lambda_ec2_isolation_dlq_arn = "arn:aws:sqs:us-east-1:123456789012:isolation-dlq"
  lambda_ec2_rollback_dlq_arn  = "arn:aws:sqs:us-east-1:123456789012:rollback-dlq"
  lambda_ip_enrichment_dlq_arn = "arn:aws:sqs:us-east-1:123456789012:enrichment-dlq"

  ecs_iam_services = {
    api = {
      ecr_repository_arns = [
        "arn:aws:ecr:us-east-1:123456789012:repository/api",
        "arn:aws:ecr:us-east-1:123456789012:repository/scanner"
      ]

      log_group_arns = [
        "arn:aws:logs:us-east-1:123456789012:log-group:/aws/ecs/unit-test-dev/api"
      ]

      execution_secret_arns = [
        "arn:aws:secretsmanager:us-east-1:123456789012:secret:app-AbCdEf",
        "arn:aws:secretsmanager:us-east-1:123456789012:secret:scanner-GhIjKl"
      ]

      execution_ssm_parameter_arns = [
        "arn:aws:ssm:us-east-1:123456789012:parameter/app/config"
      ]

      task_execution_kms_key_arns = [
        "arn:aws:kms:us-east-1:123456789012:key/22222222-2222-2222-2222-222222222222"
      ]
    }
  }
}

run "generates_scoped_execution_policy" {
  command = plan

  assert {
    condition = (
      length(aws_iam_role.ecs_task_execution_roles) == 1 &&
      length(aws_iam_role.ecs_task_roles) == 1 &&
      length(aws_iam_role_policy.ecs_task_execution_policies) == 1
    )

    error_message = "One ECS service must generate exactly one execution role, task role, and execution policy."
  }

  assert {
    condition = length([
      for statement in jsondecode(
        aws_iam_role_policy.ecs_task_execution_policies["api"].policy
      ).Statement : statement
      if statement.Sid == "AllowECRImagePulls" &&
      toset(flatten([statement.Resource])) == toset([
        "arn:aws:ecr:us-east-1:123456789012:repository/api",
        "arn:aws:ecr:us-east-1:123456789012:repository/scanner"
      ])
    ]) == 1

    error_message = "ECR image-pull permissions must cover exactly the declared primary and sidecar repositories."
  }

  assert {
    condition = length([
      for statement in jsondecode(
        aws_iam_role_policy.ecs_task_execution_policies["api"].policy
      ).Statement : statement
      if statement.Sid == "AllowSecretsManagerRead" &&
      toset(flatten([statement.Resource])) == toset([
        "arn:aws:secretsmanager:us-east-1:123456789012:secret:app-AbCdEf",
        "arn:aws:secretsmanager:us-east-1:123456789012:secret:scanner-GhIjKl"
      ])
    ]) == 1

    error_message = "Secrets Manager permissions must cover exactly the declared underlying secret ARNs."
  }

  assert {
    condition = length([
      for statement in jsondecode(
        aws_iam_role_policy.ecs_task_execution_policies["api"].policy
      ).Statement : statement
      if statement.Sid == "AllowSSMParameterRead" &&
      toset(flatten([statement.Resource])) == toset([
        "arn:aws:ssm:us-east-1:123456789012:parameter/app/config"
      ])
    ]) == 1

    error_message = "SSM permissions must be restricted to declared parameter ARNs."
  }

  assert {
    condition = length([
      for statement in jsondecode(
        aws_iam_role_policy.ecs_task_execution_policies["api"].policy
      ).Statement : statement
      if statement.Sid == "AllowExecutionKMSDecrypt" &&
      toset(flatten([statement.Resource])) == toset([
        "arn:aws:kms:us-east-1:123456789012:key/22222222-2222-2222-2222-222222222222"
      ])
    ]) == 1

    error_message = "KMS decrypt permissions must be restricted to declared execution keys."
  }
}

run "empty_services_generate_no_ecs_iam" {
  command = plan

  variables {
    ecs_iam_services = {}
  }

  assert {
    condition = (
      length(aws_iam_role.ecs_task_execution_roles) == 0 &&
      length(aws_iam_role.ecs_task_roles) == 0 &&
      length(aws_iam_role_policy.ecs_task_execution_policies) == 0 &&
      length(aws_iam_role_policy_attachment.ecs_task_managed_policies) == 0
    )

    error_message = "An empty ECS service map must generate no ECS IAM roles, execution policies, or task-role policy attachments."
  }
}