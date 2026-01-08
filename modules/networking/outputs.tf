output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnets" {
  description = "Public subnets by AZ"
  value       = aws_subnet.public
}

output "compute_private_subnets" {
  description = "Compute Private subnets by AZ"
  value       = aws_subnet.compute_private
}

output "data_private_subnets" {
  description = "Data Private subnets by AZ"
  value       = aws_subnet.data_private
}

output "serverless_private_subnets" {
  description = "Serverless Private subnets by AZ"
  value       = aws_subnet.serverless_private
}