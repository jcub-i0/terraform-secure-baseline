module "identity_center_workload" {
  for_each = var.identity_center_workloads

  source = "../../../modules/identity_center"

  account_id = each.value.account_id
  environment = each.key

  secops_operator_group_name = "SecOps-Operator-${title(each.key)}"

  secops_event_bus_arn = "arn:aws:events:${each.value.primary_region}:${each.value.account_id}:event-bus/secops-bus"

  enable_secops_analyst = each.value.enable_secops_analyst
  secops_analyst_group_name = "SecOps-Analyst-${title(each.key)}"

  enable_secops_engineer = each.value.enable_secops_engineeer
  secops_engineer_group_name = "SecOps-Engineer-${title(each.key)}"

  logs_s3_readonly_policy_name = each.value.logs_s3_readonly_policy_name
  logs_cmk_decrypt_policy_name = each.value.logs_cmk_decrypt_policy_name
}

module "identity_center_secops" {
  source = "../../../modules/identity_center"

  account_id  = var.account_id_secops
  environment = "secops"

  enable_secops_administrator     = true
  secops_administrator_group_name = "SecOps-Administrator"

  enable_secops_analyst = var.enable_secops_analyst_secops
  secops_analyst_group_name = (
    var.enable_secops_analyst_secops
    ? "SecOps-Analyst-SecOps"
    : null
  )

  enable_secops_engineer = var.enable_secops_engineer_secops
  secops_engineer_group_name = (
    var.enable_secops_engineer_secops
    ? "SecOps-Engineer-SecOps"
    : null
  )

  logs_s3_readonly_policy_name = var.logs_s3_readonly_policy_name_secops
  logs_cmk_decrypt_policy_name = var.logs_cmk_decrypt_policy_name_secops
}