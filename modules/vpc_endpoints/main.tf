locals {
  private_subnet_ids = concat(
    var.compute_private_subnet_ids_list,
    var.data_private_subnet_ids_list,
    var.serverless_private_subnet_ids_list
  )
}

# GET ROUTE TABLE FOR EACH PRIVATE SUBNET
data "aws_route_table" "private" {
  for_each = toset(local.private_subnet_ids)
  subnet_id = each.value
}

# GET ROUTE TABLE FOR EACH PUBLIC SUBNET
data "aws_route_table" "public" {
  
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