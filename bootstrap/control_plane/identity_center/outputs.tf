output "workload_permission_set_arns" {
  description = "Permission set ARNs by workload environment"

  value = {
    for environment, identity_center in module.identity_center_workload :
    environment => module.identity_center_workload.permission_set_arns
  }
}

output "secops_permission_set_arns" {
  description = "Permission set ARNs for the security-operations account"
  value       = module.identity_center_secops.permission_set_arns
}