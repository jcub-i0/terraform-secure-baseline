output "interface_endpoints_sg_id" {
  value = aws_security_group.interface_endpoints_sg.id
}

output "interface_endpoint_ids" {
  value = {
    for service, endpoint in aws_vpc_endpoint.interface :
    service => endpoint.id
  }
}