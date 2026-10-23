resource "aws_security_group" "worker" {
  name                   = "${var.name_prefix}-Restore-Validation-Worker-SG"
  description            = "Private PostgreSQL restore validation worker"
  vpc_id                 = var.vpc_id
  revoke_rules_on_delete = true

  tags = {
    Name        = "${var.name_prefix}-Restore-Validation-Worker-SG"
    Environment = var.environment
    Terraform   = "true"
  }
}