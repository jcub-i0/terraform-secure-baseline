output "logs_s3_readonly_policy_name" {
  value = aws_iam_policy.logs_s3_readonly.name
}

output "logs_cmk_decrypt_policy_name" {
  value = aws_iam_policy.logs_cmk_decrypt.name
}

output "break_glass_admin_role_arn" {
  value = aws_iam_role.break_glass_admin.arn
}
