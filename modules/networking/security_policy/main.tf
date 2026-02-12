# SECURITY GROUP RULES

## COMPUTE SG RULES
resource "aws_security_group_rule" "compute_egress_to_endpoints" {
  type = "egress"
  security_group_id = var.compute_sg_id
  from_port = 443
  to_port = 443
  protocol = "tcp"
  source_security_group_id = var.interface_endpoints_sg_id
  description = "Compute -> VPC endpoints over HTTPS"
}

resource "aws_security_group_rule" "compute_egress_to_db" {
  type = "egress"
  security_group_id = var.compute_sg_id
  from_port = var.db_port
  to_port = var.db_port
  protocol = "tcp"
  source_security_group_id = var.data_sg_id
  description = "Compute -> DB"
}