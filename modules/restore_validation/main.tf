# RESTORE VALIDATION WORKER -> RESTORED RDS
resource "aws_security_group_rule" "restore_worker_to_db" {
  type                     = "egress"
  security_group_id        = aws_security_group.worker.id
  from_port                = var.db_port
  to_port                  = var.db_port
  protocol                 = "tcp"
  source_security_group_id = var.restore_db_sg_id
  description              = "Allow validation worker to connect to restored PostgreSQL"
}

# RESTORED RDS <- RESTORE VALIDATION WORKER
resource "aws_security_group_rule" "restore_db_from_worker" {
  type                     = "ingress"
  security_group_id        = var.restore_db_sg_id
  from_port                = var.db_port
  to_port                  = var.db_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.worker.id
  description              = "Allow PostgreSQL access from restore validation worker"
}

# RESTORE VALIDATION WORKER -> VPC INTERFACE ENDPOINTS
resource "aws_security_group_rule" "restore_worker_to_endpoints" {
  type                     = "egress"
  security_group_id        = aws_security_group.worker.id
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = var.interface_endpoints_sg_id
  description              = "Allow validation worker to reach AWS PrivateLink endpoints"
}

# VPC INTERFACE ENDPOINTS <- RESTORE VALIDATION WORKER
resource "aws_security_group_rule" "endpoints_from_restore_worker" {
  type                     = "ingress"
  security_group_id        = var.interface_endpoints_sg_id
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.worker.id
  description              = "Allow restore validation worker to access interface endpoints"
}