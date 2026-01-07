# CREATE MAIN VPC
resource "aws_vpc" "main" {
  cidr_block = var.main_vpc_cidr
  tags = {
    Name      = "Main-TF-Secure-Baseline"
    Terraform = "true"
  }
}

# CREATE SUBNETS
## PUBLIC SUBNETS
resource "aws_subnet" "public" {
  for_each = var.public_subnet_cidrs

  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value
  availability_zone = each.key
}

## COMPUTE PRIVATE SUBNETS
resource "aws_subnet" "compute_private" {
  for_each = var.compute_private_subnet_cidrs

  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value
  availability_zone = each.key

  tags = {
    Name      = "Compute-Private-${each.key}"
    Terraform = "true"
  }
}

## DATA PRIVATE SUBNETS
resource "aws_subnet" "data_private" {
  for_each = var.data_private_subnet_cidrs

  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value
  availability_zone = each.key

  tags = {
    Name      = "Data-Private-${each.key}"
    Terraform = "true"
  }
}

## SERVERLESS PRIVATE SUBNETS
resource "aws_subnet" "serverless_private" {
  for_each = var.serverless_private_subnet_cidrs

  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value
  availability_zone = each.key

  tags = {
    Name      = "Serverless-Private-${each.key}"
    Terraform = "true"
  }
}

# CREATE IGW, EIP, and NATGW
## IGW
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name      = "IGW"
    Terraform = "true"
  }
}

## EIP
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name      = "NAT-EIP"
    Terraform = "true"
  }
}

## NATGW
resource "aws_nat_gateway" "natgw" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id

  depends_on = [aws_internet_gateway.igw]

  tags = {
    Name      = "NAT-Gateway"
    Terraform = "true"
  }
}

# CREATE AND ASSOCIATE ROUTE TABLES
## PUBLIC ROUTE TABLE
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "Public-Route-Table"
    Terraform = "true"
  }
}