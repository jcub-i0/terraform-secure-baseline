# CREATE SECURITY GROUPS FOR EC2
## COMPUTE SECURITY GROUP
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

## QUARANTINE SECURITY GROUP
resource "aws_security_group" "quarantine" {
  name = "Quarantine-SG"
  description = "Security Group for isolating EC2 instances suspected of compromisation so that security triage and remediation can be performed safely without allowing unrestricted network access"
  vpc_id = var.vpc_id

  egress {
    from_port = 443
    to_port = 443
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow ONLY HTTPS egress for SSM and forensics"
  }

  tags = {
    Name = "EC2-Quarantine-SG"
    Terraform = "true"
    Purpose = "IncidentResponse"
  }
}

# CREATE EC2 INSTANCES
## EC2 INSTANCE AMI
data "aws_ami" "ec2" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = [var.ec2_ami_name]
  }
}

## EC2 INSTANCE
resource "aws_instance" "ec2" {
  for_each = var.compute_private_subnet_ids_map
  ami                    = data.aws_ami.ec2.id
  instance_type          = "t3.micro"
  subnet_id              = each.value
  vpc_security_group_ids = [aws_security_group.compute.id]
  monitoring             = true

  tags = {
    Name      = "EC2"
    Terraform = "true"
    Purpose = "Receives input from users or other services, transforms it, validates it, and/or aggregates it"
  }
}