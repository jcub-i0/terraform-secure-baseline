output "account_id" {
  description = "ID of the AWS account managing this environment"
  value       = data.aws_caller_identity.current.account_id
}

output "tf_state_bucket_arn" {
  description = "ARN of the S3 bucket where the Terraform state is stored"
  value       = module.state.tf_state_bucket_arn
}

output "tf_state_bucket_name" {
  description = "Name of the S3 bucket where the Terraform state is stored"
  value       = module.state.tf_state_bucket_name
}

output "tf_state_bucket_cmk_arn" {
  description = "ARN of the KMS CMK used to encrypt the Terraform State bucket"
  value       = module.state.tf_state_bucket_cmk_arn
}

output "application_state_backends" {
  description = "Application backend settings and exact resources for protected deployment IAM."
  value = {
    for application, backend in module.application_state : application => {
      backend       = backend.backend
      iam_resources = backend.iam_resources
    }
  }
}