locals {
  private_subnet_ids = concat(
    var.compute_subnet_ids_list,
    var.data_private_subnet_ids_list,
    var.serverless_private_subnet_ids_list
  )
}

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