output "interface_endpoints_sg_id" {
  value = aws_security_group.interface_endpoints_sg.id
}

output "interface_endpoint_ids" {
  value = {
    for service, endpoint in aws_vpc_endpoint.interface :
    service => endpoint.id
  }
}

output "s3_prefix_list_id" {
  description = "Prefix list ID associated with the S3 Gateway VPC Endpoint"
  value = aws_vpc_endpoint.s3.prefix_list_id
}