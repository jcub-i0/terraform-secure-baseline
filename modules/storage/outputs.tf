output "centralized_logs_bucket_name" {
  description = "The 'bucket' attribute of the Centralized Logs S3 bucket"
  value       = aws_s3_bucket.centralized_logs.bucket
}

output "centralized_logs_bucket_arn" {
  description = "The ARN of the Centralized Logs S3 bucket"
  value       = aws_s3_bucket.centralized_logs.arn
}

output "centralized_logs_bucket_id" {
  description = "The ID of the Centralized Logs S3 bucket"
  value       = aws_s3_bucket.centralized_logs.id
}

output "data_sg_id" {
  description = "ID of the RDS/data security group"
  value       = aws_security_group.data.id
}

output "rds_address" {
  description = "DNS address of the RDS instance"
  value       = aws_db_instance.main.address
}

output "rds_endpoint" {
  description = "Connection endpoint of the RDS instance in address:port form"
  value       = aws_db_instance.main.endpoint
}

output "rds_port" {
  description = "Port on which the RDS instance accepts connections"
  value       = aws_db_instance.main.port
}

output "rds_database_name" {
  description = "Initial database name configured on the RDS instance"
  value       = aws_db_instance.main.db_name
}

output "rds_master_username" {
  description = "Master username configured on the RDS instance"
  value       = aws_db_instance.main.username
}

output "rds_master_secret_arn" {
  description = "ARN of the Secrets Manager secret containing the RDS master password"
  value       = aws_secretsmanager_secret.rds_master.arn
}

output "rds_configuration" {
  description = "Validator-relevant Terraform-managed RDS configuration."

  value = {
    identifier = aws_db_instance.main.identifier
    arn        = aws_db_instance.main.arn

    multi_az = aws_db_instance.main.multi_az

    db_subnet_group_name = (
      aws_db_instance.main.db_subnet_group_name
    )

    vpc_security_group_ids = (
      aws_db_instance.main.vpc_security_group_ids
    )

    deletion_protection = (
      aws_db_instance.main.deletion_protection
    )

    backup_retention_period = (
      aws_db_instance.main.backup_retention_period
    )

    publicly_accessible = (
      aws_db_instance.main.publicly_accessible
    )

    storage_encrypted = (
      aws_db_instance.main.storage_encrypted
    )

    skip_final_snapshot = (
      aws_db_instance.main.skip_final_snapshot
    )

    delete_automated_backups = (
      aws_db_instance.main.delete_automated_backups
    )

    final_snapshot_identifier = (
      aws_db_instance.main.final_snapshot_identifier
    )
  }
}