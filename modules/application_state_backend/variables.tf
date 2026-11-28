variable "name_prefix" {
  description = "Application/environment prefix for the backend key alias and tags."
  type        = string
}

variable "environment" {
  type = string
}

variable "bucket_name" {
  description = "Globally unique bucket name dedicated to this application/environment."
  type        = string
}

variable "access" {
  description = "Exact platform-administered roles; include the bootstrap writer in administrator_role_arns."
  type = object({
    plan_role_arn           = string
    apply_role_arn          = string
    administrator_role_arns = set(string)
  })
  nullable = false

  validation {
    condition = alltrue([
      for arn in concat(
        [var.access.plan_role_arn, var.access.apply_role_arn],
        tolist(var.access.administrator_role_arns)
        ) : can(regex(
          "^arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/[A-Za-z0-9+=,.@_/-]+$",
          arn
      ))
    ])
    error_message = "Backend access requires exact IAM role ARNs in this account and partition; wildcard and session ARNs are not allowed."
  }

  validation {
    condition = (
      length(var.access.administrator_role_arns) > 0 &&
      var.access.plan_role_arn != var.access.apply_role_arn &&
      length(setintersection(
        var.access.administrator_role_arns,
        toset([var.access.plan_role_arn, var.access.apply_role_arn])
      )) == 0
    )
    error_message = "Plan and Apply must be distinct roles, with at least one separate platform administrator."
  }
}
