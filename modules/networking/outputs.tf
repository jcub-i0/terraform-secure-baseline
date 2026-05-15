output "vpc_id" {
  value = aws_vpc.main.id
}

# For resources using for_each patterns
output "nat_gateway_ids_map" {
  description = "map(string) of NATGW IDs by AZ"
  value       = { for az, natgw in aws_nat_gateway.natgw : az => natgw.id }
}

output "public_subnet_ids_map" {
  description = "map(string) of Public Subnet IDs by AZ"
  value       = { for az, subnet in aws_subnet.public : az => subnet.id }
}

output "compute_private_subnet_ids_map" {
  description = "map(string) of Compute Private Subnet IDs"
  value       = { for az, subnet in aws_subnet.compute_private : az => subnet.id }
}

output "data_private_subnet_ids_map" {
  description = "map(string) of Data Private Subnet IDs"
  value       = { for az, subnet in aws_subnet.data_private : az => subnet.id }
}

output "serverless_private_subnet_ids_map" {
  description = "map(string) of Serverless Private Subnet IDs"
  value       = { for az, subnet in aws_subnet.serverless_private : az => subnet.id }
}

output "firewall_private_subnet_ids_map" {
  description = "map(string) of Firewall Private Subnet IDs"
  value       = { for az, subnet in aws_subnet.firewall_private : az => subnet.id }
}

output "endpoint_private_subnet_ids_map" {
  description = "map(string) of Endpoint Private Subnet IDs"
  value = { for az, subnet in aws_subnet.endpoint_private : az => aws_subnet.id }
}

output "endpoint_private_rt_ids_map" {
  description = "map(string) of Endpoint Private Route Table IDs"
  value       = { for az, rt in aws_route_table.endpoint_private : az => rt.id }
}

# For resources that need list(string) (i.e. RDS)
output "public_subnet_ids_list" {
  description = "list(string) of Public Subnet IDs"
  value       = [for subnet in aws_subnet.public : subnet.id]
}

output "compute_private_subnet_ids_list" {
  description = "list(string) of Compute Private Subnet IDs"
  value       = [for subnet in aws_subnet.compute_private : subnet.id]
}

output "data_private_subnet_ids_list" {
  description = "list(string) of Data Private Subnet IDs"
  value       = [for subnet in aws_subnet.data_private : subnet.id]
}

output "serverless_private_subnet_ids_list" {
  description = "list(string) of Serverless Private Subnet IDs"
  value       = [for subnet in aws_subnet.serverless_private : subnet.id]
}

output "firewall_private_subnet_ids_list" {
  description = "list(string) of Firewall Private Subnet IDs"
  value       = [for subnet in aws_subnet.firewall_private : subnet.id]
}

output "endpoint_private_subnet_ids_list" {
  description = "list(string) of Endpoint Private Subnet IDs"
  value       = [for subnet in aws_subnet.aws_subnet.endpoint_private : subnet.id]
}