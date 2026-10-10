data "aws_partition" "current" {}

module "identity_center_workload" {
  for_each = var.identity_center_workloads

  source = "../../../modules/identity_center"

  account_id  = each.value.account_id
  environment = each.key

  enable_secops_operator     = true
  secops_operator_group_name = "SecOps-Operator-${title(each.key)}"

  secops_event_bus_arn = "arn:${data.aws_partition.current.partition}:events:${each.value.primary_region}:${each.value.account_id}:event-bus/${var.cloud_name}-${each.key}-secops-bus"
}

module "identity_center_secops" {
  source = "../../../modules/identity_center"

  account_id  = var.identity_center_secops.account_id
  environment = "secops"

  enable_secops_administrator     = true
  secops_administrator_group_name = "SecOps-Administrator"

  enable_secops_operator = false
}
