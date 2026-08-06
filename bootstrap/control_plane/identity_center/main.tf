module "identity_center_workload" {
  for_each = var.identity_center_workloads

  source = "../../../modules/identity_center"

  account_id  = each.value.account_id
  environment = each.key

  enable_secops_operator = true
  secops_operator_group_name = "SecOps-Operator-${title(each.key)}"

  secops_event_bus_arn = "arn:aws:events:${each.value.primary_region}:${each.value.account_id}:event-bus/secops-bus"

  enable_secops_analyst     = each.value.enable_secops_analyst
  secops_analyst_group_name = "SecOps-Analyst-${title(each.key)}"

  enable_secops_engineer     = each.value.enable_secops_engineer
  secops_engineer_group_name = "SecOps-Engineer-${title(each.key)}"

  logs_s3_readonly_policy_name = each.value.logs_s3_readonly_policy_name
  logs_cmk_decrypt_policy_name = each.value.logs_cmk_decrypt_policy_name
}

module "identity_center_secops" {
  source = "../../../modules/identity_center"

  account_id  = var.identity_center_secops.account_id
  environment = "secops"

  enable_secops_administrator     = true
  secops_administrator_group_name = "SecOps-Administrator"

  enable_secops_operator = false

  enable_secops_analyst = (
    var.identity_center_secops.enable_secops_analyst
  )

  secops_analyst_group_name = (
    var.identity_center_secops.enable_secops_analyst
    ? "SecOps-Analyst-SecOps"
    : null
  )

  enable_secops_engineer = (
    var.identity_center_secops.enable_secops_engineer
  )

  secops_engineer_group_name = (
    var.identity_center_secops.enable_secops_engineer
    ? "SecOps-Engineer-SecOps"
    : null
  )

  logs_s3_readonly_policy_name = (
    var.identity_center_secops.logs_s3_readonly_policy_name
  )

  logs_cmk_decrypt_policy_name = (
    var.identity_center_secops.logs_cmk_decrypt_policy_name
  )
}