# CREATE SECURITY GROUPS FOR EC2
## COMPUTE SECURITY GROUP
resource "aws_security_group" "compute" {
  name        = "Compute-SG"
  description = "Security Group for EC2 compute instances"
  vpc_id      = var.vpc_id

  tags = {
    Name      = "Compute-SG"
    Terraform = "true"
  }
}

## QUARANTINE SECURITY GROUP
resource "aws_security_group" "quarantine" {
  name        = "Quarantine-SG"
  description = "Security Group for isolating EC2 instances suspected of compromisation so that security triage and remediation can be performed safely without allowing unrestricted network access"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow ONLY HTTPS egress for SSM and forensics"
  }

  tags = {
    Name      = "EC2-Quarantine-SG"
    Terraform = "true"
    Purpose   = "IncidentResponse"
  }
}

# CREATE EC2 INSTANCES
## EC2 INSTANCE AMI
data "aws_ami" "ec2" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server*"]
  }
}

## EC2 INSTANCE
resource "aws_instance" "ec2" {
  for_each               = var.compute_private_subnet_ids_map
  ami                    = data.aws_ami.ec2.id
  instance_type          = "t3.micro"
  subnet_id              = each.value
  vpc_security_group_ids = [aws_security_group.compute.id]
  monitoring             = true
  iam_instance_profile   = var.instance_profile_name

  metadata_options {
    http_tokens                 = "optional" # Temporary - using this as a sample 'HIGH' finding in Security Hub
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
    kms_key_id  = var.ebs_kms_key_arn
  }

  tags = {
    Name             = "EC2-${each.key}"
    Terraform        = "true"
    Purpose          = "Receives input from users or other services, transforms it, validates it, and/or aggregates it"
    IsolationAllowed = "true"
  }
}