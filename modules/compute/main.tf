/*resource "aws_security_group" "compute" {
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

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server*"]
  }
}

resource "aws_instance" "ec2" {
  for_each = var.compute_private_subnets
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  subnet_id              = each.value.id
  vpc_security_group_ids = [aws_security_group.compute.id]
  monitoring             = true

  tags = {
    Name      = "EC2"
    Terraform = "true"
  }
}
*/