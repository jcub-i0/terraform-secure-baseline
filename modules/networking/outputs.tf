output "vpc_id" {
  value = aws_vpc.main.id
}

# For for_each patterns
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

# For resources that need list(string) (i.e. RDS)
output "public_subnet_ids_list" {
  description = "list(string) of Public Subnet IDs"
  value       = [for subnet in aws_subnet.public : subnet.id]
}

output "compute_subnet_ids_list" {
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