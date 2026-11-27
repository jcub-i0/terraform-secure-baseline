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
