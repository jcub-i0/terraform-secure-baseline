resource "aws_security_group" "compute" {
  name        = "Compute-SG"
  description = "Security Group for EC2 compute instances"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound HTTP traffic"
  }

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound HTTPS traffic"
  }

  tags = {
    Name      = "Compute-SG"
    Terraform = "true"
  }
}