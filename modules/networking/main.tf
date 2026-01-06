# CREATE MAIN VPC
resource "aws_vpc" "main" {
  cidr_block = var.main_vpc_cidr
  tags = {
    Name = "Main-TF-Secure-Baseline"
    Terraform = "true"
  }
}

# CREATE PRIVATE SUBNETS
resource "aws_subnet" "data_private_subnet" {
    for_each = var.data_private_subnet_cidrs

    vpc_id = aws_vpc.main.id
    cidr_block = each.value
    availability_zone = each.key

    tags = {
      Name = "Data-Private-${each.key}"
      Terraform = "true"
    }
}