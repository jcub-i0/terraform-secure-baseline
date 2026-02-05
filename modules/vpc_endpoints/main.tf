locals {
  private_subnet_ids = concat(
    var.compute_private_subnet_ids_list,
    var.data_private_subnet_ids_list,
    var.serverless_private_subnet_ids_list
  )
  private_subnet_cidrs = flatten([
    for subnet, cidr in var.subnet_cidrs :
    cidr if endswith(subnet, "_private")
  ])
}

# GET ROUTE TABLE FOR EACH PRIVATE SUBNET
data "aws_route_table" "private" {
  for_each = toset(local.private_subnet_ids)
  subnet_id = each.value
}

# GATEWAY ENDPOINTS (S3, DYNAMODB)
resource "aws_vpc_endpoint" "s3" {
  vpc_id = var.vpc_id
  service_name = "com.amazonaws.${var.primary_region}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = [for rt in values(data.aws_route_table.private) : rt.id]

  tags = {
    Name = "S3-Gateway-Endpoint"
    Terraform = "true"
  }
}

# INTERFACE ENDPOINTS

## SECURITY GROUP FOR ALL INTERFACE VPC ENDPOINTS
resource "aws_security_group" "interface_endpoints_sg" {
  name = "vpc-endpoints-sg"
  description = "Security Group for Interface VPC Endpoints (AWS PrivateLink)"
  vpc_id = var.vpc_id

  ingress {
    from_port = 443
    to_port = 443
    protocol = "tcp"
    cidr_blocks = local.private_subnet_cidrs
    description = "Allow AWS services to communicate with VPC Endpoints"
  }

  egress {
    from_port = 443
    to_port = 443
    protocol = "tcp"
    cidr_blocks = local.private_subnet_cidrs
    description = "Allow VPC Endpoints to communicate with AWS services"
  }

  tags = {
    Name = "VPC-Endpoints-SG"
    Terraform = "true"
  }
}

resource "aws_vpc_endpoint" "sts" {
  vpc_id = var.vpc_id
  service_name = "com.amazonaws.${var.primary_region}.sts"
  vpc_endpoint_type = "Interface"
  subnet_ids = local.private_subnet_ids
  security_group_ids = [aws_security_group.interface_endpoints_sg.id]
  private_dns_enabled = true
}