output "compute_sg_rule_ids" {
  description = "Security Group rule IDs that must exist before compute EC2 instances launch"

  value = {
    endpoints_ingress_from_compute = aws_security_group_rule.endpoints_ingress_from_compute.id
    compute_egress_to_endpoints    = aws_security_group_rule.compute_egress_to_endpoints.id
    compute_egress_to_db           = aws_security_group_rule.compute_egress_to_db.id

    compute_egress_to_internet_https = try(
      aws_security_group_rule.compute_egress_to_internet_https[0].id,
      null
    )
  }
}