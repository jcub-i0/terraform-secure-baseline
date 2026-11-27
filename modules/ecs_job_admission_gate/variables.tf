variable "name_prefix" {
  description = "Resource naming prefix unique to this application and environment."
  type        = string
}

variable "environment" {
  description = "Environment identifier for resource tags."
  type        = string
}

variable "admission_gate_cmk_arn" {
  description = "Foundation-controlled customer-managed KMS key ARN for the admission gate."
  type        = string

  validation {
    condition = can(regex(
      "^arn:(aws|aws-us-gov|aws-cn):kms:[a-z0-9-]+:[0-9]{12}:key/[A-Za-z0-9-]+$",
      var.admission_gate_cmk_arn
    ))
    error_message = "The admission gate requires an exact customer-managed KMS key ARN."
  }
}

variable "admission_gate" {
  description = "Protected foundation gate references. Null adds no gate-access permissions."
  type = object({
    table_arn = string
    cmk_arn   = string
  })
  default = null

  validation {
    condition = var.admission_gate == null ? true : try(
      can(regex(
        "^arn:(aws|aws-us-gov|aws-cn):dynamodb:[a-z0-9-]+:[0-9]{12}:table/[A-Za-z0-9_.-]+$",
        var.admission_gate.table_arn
      )) &&
      can(regex(
        "^arn:(aws|aws-us-gov|aws-cn):kms:[a-z0-9-]+:[0-9]{12}:key/[A-Za-z0-9-]+$",
        var.admission_gate.cmk_arn
      )) &&
      alltrue([
        for arn in [var.admission_gate.table_arn, var.admission_gate.cmk_arn] :
        regex("^arn:([^:]+):[^:]+:([^:]+):([^:]+):", arn) ==
        regex("^arn:([^:]+):[^:]+:([^:]+):([^:]+):", var.approved_cluster_arn)
      ]) &&
      split("/", var.admission_gate.table_arn)[1] != "${var.name_prefix}-job-execution-ledger",
      false
    )
    error_message = "The gate requires exact table/key ARNs in the approved cluster's partition, account, and Region, and must be separate from the execution ledger."
  }
}