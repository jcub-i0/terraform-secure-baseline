# CREATE DATA SECURITY GROUP AND RDS INSTANCE
## DATA SECURITY GROUP
resource "aws_security_group" "data" {
  name        = "Data-SG"
  description = "Security Group for the RDS database"
  vpc_id      = var.vpc_id

  # Ingress from Compute EC2 instances
  ingress {
    from_port       = var.db_port
    to_port         = var.db_port
    protocol        = "tcp"
    security_groups = [var.compute_sg_id]
    description     = "Allow DB access from compute tier"
  }

  # Egress -- outbound to AWS services
  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Outbound HTTPS for AWS services"
  }

  tags = {
    Name      = "Data-SG"
    Terraform = "true"
  }
}