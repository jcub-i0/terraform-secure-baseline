locals {
  # Loop over var.azs using the index (indx) to pick the CIDR for that AZ
  az_index_map = { for indx, az in var.azs : az => indx }
}

# CREATE MAIN VPC
resource "aws_vpc" "main" {
  cidr_block           = var.main_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name      = "Main-TF-Secure-Baseline"
    Terraform = "true"
  }
}

# CREATE SUBNETS
## PUBLIC SUBNETS
resource "aws_subnet" "public" {
  for_each = local.az_index_map

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.subnet_cidrs.public[each.value]
  availability_zone       = each.key
  map_public_ip_on_launch = false

  tags = {
    Name      = "Public-Subnet-${each.key}"
    Terraform = "true"
  }
}

## COMPUTE PRIVATE SUBNETS
resource "aws_subnet" "compute_private" {
  for_each = local.az_index_map

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.subnet_cidrs.compute_private[each.value]
  availability_zone       = each.key
  map_public_ip_on_launch = false

  tags = {
    Name      = "Compute-Private-${each.key}"
    Terraform = "true"
  }
}

## DATA PRIVATE SUBNETS
resource "aws_subnet" "data_private" {
  for_each = local.az_index_map

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.subnet_cidrs.data_private[each.value]
  availability_zone       = each.key
  map_public_ip_on_launch = false

  tags = {
    Name      = "Data-Private-${each.key}"
    Terraform = "true"
  }
}

## SERVERLESS PRIVATE SUBNETS
resource "aws_subnet" "serverless_private" {
  for_each                = local.az_index_map
  map_public_ip_on_launch = false

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.subnet_cidrs.serverless_private[each.value]
  availability_zone = each.key

  tags = {
    Name      = "Serverless-Private-${each.key}"
    Terraform = "true"
  }
}

## FIREWALL PRIVATE SUBNETS
resource "aws_subnet" "firewall_private" {
  for_each                = local.az_index_map
  map_public_ip_on_launch = false

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.subnet_cidrs.firewall_private[each.value]
  availability_zone = each.key

  tags = {
    Name      = "Firewall-Private-${each.key}"
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
  for_each = local.az_index_map
  domain   = "vpc"

  tags = {
    Name      = "NAT-EIP-${each.key}"
    Terraform = "true"
  }
}

## NATGW
resource "aws_nat_gateway" "natgw" {
  for_each      = local.az_index_map
  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.public[each.key].id

  depends_on = [aws_internet_gateway.igw]

  tags = {
    Name      = "NAT-Gateway-${each.key}"
    Terraform = "true"
  }
}

# CREATE AND ASSOCIATE ROUTE TABLES
## PUBLIC ROUTE TABLE
resource "aws_route_table" "public" {
  for_each = local.az_index_map
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  route {
    cidr_block = var.subnet_cidrs.compute_private[each.value]
    vpc_endpoint_id = var.firewall_endpoint_ids_by_az[each.key]
  }

  tags = {
    Name      = "Public-Route-Table"
    Terraform = "true"
  }
}

## PUBLIC ROUTE TABLE ASSOCIATION
resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  route_table_id = aws_route_table.public.id
  subnet_id      = each.value.id
}

## PRIVATE ROUTE TABLES

### COMPUTE PRIVATE SUBNET ROUTE TABLE PER AZ
resource "aws_route_table" "compute_private" {
  for_each = local.az_index_map
  vpc_id   = aws_vpc.main.id

  tags = {
    Name      = "Compute-Private-RT-${each.key}"
    Terraform = "true"
  }
}

resource "aws_route" "compute_default_to_firewall" {
  for_each               = local.az_index_map
  route_table_id         = aws_route_table.compute_private[each.key].id
  destination_cidr_block = "0.0.0.0/0"

  vpc_endpoint_id = var.firewall_endpoint_ids_by_az[each.key]
}

### FIREWALL PRIVATE ROUTE TABLE PER AZ
resource "aws_route_table" "firewall_private" {
  for_each = local.az_index_map
  vpc_id   = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.natgw[each.key].id
  }

  tags = {
    Name      = "Firewall-Private-RT-${each.key}"
    Terraform = "true"
  }
}

### DATA PRIVATE ROUTE TABLE PER AZ
resource "aws_route_table" "data_private" {
  for_each = local.az_index_map
  vpc_id   = aws_vpc.main.id

  tags = {
    Name      = "Data-Private-RT-${each.key}"
    Terraform = "true"
  }
}

### SERVERLESS PRIVATE ROUTE TABLE PER AZ
resource "aws_route_table" "serverless_private" {
  for_each = local.az_index_map
  vpc_id   = aws_vpc.main.id

  tags = {
    Name      = "Serverless-Private-RT-${each.key}"
    Terraform = "true"
  }
}

## PRIVATE ROUTE TABLE ASSOCIATIONS
resource "aws_route_table_association" "compute_private" {
  for_each = local.az_index_map

  route_table_id = aws_route_table.compute_private[each.key].id
  subnet_id      = aws_subnet.compute_private[each.key].id
}

resource "aws_route_table_association" "firewall_private" {
  for_each = local.az_index_map

  route_table_id = aws_route_table.firewall_private[each.key].id
  subnet_id      = aws_subnet.firewall_private[each.key].id
}

resource "aws_route_table_association" "data_private" {
  for_each = local.az_index_map

  route_table_id = aws_route_table.data_private[each.key].id
  subnet_id      = aws_subnet.data_private[each.key].id
}

resource "aws_route_table_association" "serverless_private" {
  for_each = local.az_index_map

  route_table_id = aws_route_table.serverless_private[each.key].id
  subnet_id      = aws_subnet.serverless_private[each.key].id
}