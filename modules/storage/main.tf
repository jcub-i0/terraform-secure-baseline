data "aws_caller_identity" "current" {}

# CREATE DATA SECURITY GROUP, DB Subnet Group, AND RDS INSTANCE
## DATA SECURITY GROUP
resource "aws_security_group" "data" {
  name        = "Data-SG"
  description = "Security Group for the RDS database"
  vpc_id      = var.vpc_id

  # Ingress from Compute EC2 instances
  ingress {
    from_port       = var.db_port
    to_port         = var.db_port
    protocol        = "tcp"
    security_groups = [var.compute_sg_id]
    description     = "Allow DB access from compute tier"
  }

  # Egress -- outbound to AWS services
  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Outbound HTTPS for AWS services"
  }

  tags = {
    Name      = "Data-SG"
    Terraform = "true"
  }
}

## DB SUBNET GROUP
resource "aws_db_subnet_group" "data" {
  name       = "data-db-subnet-group"
  subnet_ids = var.data_private_subnet_ids_list

  tags = {
    Name      = "Data-DB-Subnet-Group"
    Terraform = "true"
  }
}

## RDS Instance
resource "aws_db_instance" "main" {
  identifier = "saas-data-db"

  engine         = "postgres"
  engine_version = "16.6"
  instance_class = "db.t4g.medium"

  allocated_storage     = 50
  max_allocated_storage = 200
  storage_type          = "gp3"
  storage_encrypted     = true

  db_subnet_group_name   = aws_db_subnet_group.data.name
  vpc_security_group_ids = [aws_security_group.data.id]

  multi_az            = true
  publicly_accessible = false

  db_name  = "appdb"
  username = var.db_username
  password = var.db_password
  # UNCOMMENT THIS IF YOU WANT A RANDOMLY-GENERATED EPHEMERAL PASSWORD THAT IS NEVER PERSISTED TO STATE (AND ALSO DELETE THE ABOVE LINE)
  # password = jsondecode(data.aws_secretsmanager_secret_version.rds_master.secret_string)["password"]

  deletion_protection     = false # CHANGE THIS TO 'TRUE' FOR A PRODUCTION ENVIRONMENT
  skip_final_snapshot     = true  # CHANGE THIS TO 'FALSE' FOR A PRODUCTION ENVIRONMENT
  backup_retention_period = 14
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:05:00-sun:06:00"

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  performance_insights_enabled = true
  # monitoring_interval = 60 # IAM ROLE IS REQUIRED TO DO THIS

  auto_minor_version_upgrade = true

  tags = {
    Name      = "SaaS-RDS"
    Terraform = "true"
  }
}

# UNCOMMENT THIS AND REMOVE var.db_password (AND ITS REFERENCES) IF YOU WANT A RANDOMLY-GENERATED EPHEMERAL PASSWORD THAT IS NEVER PERSISTED TO STATE
/*
# RDS SECRET GENERATION/HANDLING, WHERE THE SECRET IS NEVER PERSISTED TO THE STATE
## Create a secret in AWS Secrets Manager
resource "aws_secretsmanager_secret" "rds_master" {
  name = "rds-secret"
}

## Generate random secret
ephemeral "aws_secretsmanager_random_password" "rds_master" {
  password_length = 20
}

## Store generated secret inside the secret in AWS Secrets Manager
resource "aws_secretsmanager_secret_version" "rds_master" {
  secret_id = aws_secretsmanager_secret.rds_master.id
  secret_string_wo = jsonencode({
    password = ephemeral.aws_secretsmanager_random_password.rds_master.random_password
  })
  secret_string_wo_version = 1
}

## Access the generated secret inside the AWS Secrets Manager secret
data "aws_secretsmanager_secret_version" "rds_master" {
  secret_id = aws_secretsmanager_secret.rds_master.id
}
*/

# S3 RESOURCES
## CENTRALIZED LOGS S3 BUCKET
resource "aws_s3_bucket" "centralized_logs" {
  bucket        = "tf-baseline-centralized-logs"
  force_destroy = true # DELETE THIS FOR PRODUCTION ENVIRONMENT

  tags = {
    Name      = "TF-Baseline-Centralized-Logs"
    Terraform = "true"
  }
}

## BLOCK PUBLIC ACCESS TO THE CENTRALIZED LOGS S3 BUCKET
resource "aws_s3_bucket_public_access_block" "centralized_logs" {
  bucket = aws_s3_bucket.centralized_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

## ENABLE SSE FOR THE CENTRALIZED LOGS S3 BUCKET
resource "aws_s3_bucket_server_side_encryption_configuration" "centralized_logs" {
  bucket = aws_s3_bucket.centralized_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.logs_kms_key_arn
    }
    bucket_key_enabled = true
  }
}

## ENABLE VERSIONING FOR THE CENTRALIZED LOGS S3 BUCKET
resource "aws_s3_bucket_versioning" "centralized_logs" {
  bucket = aws_s3_bucket.centralized_logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

## ENSURE BUCKET OWNER ALWAYS OWNS ALL OBJECTS, REGARDLESS OF UPLOADER.
## THIS DISABLES ACLs AND AVOIDS CROSS-ACCOUTN WRITE PERMISSION ISSUES.
resource "aws_s3_bucket_ownership_controls" "centralized_logs" {
  bucket = aws_s3_bucket.centralized_logs.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

## S3 BUCKET POLICIES
### CENTRALIZED LOGS S3 BUCKET POLICY
resource "aws_s3_bucket_policy" "centralized_logs" {
  bucket = aws_s3_bucket.centralized_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
        # CLOUDTRAIL
        ## ALLOW CLOUDTRAIL TO VERIFY BUCKET ACL
        {
            Sid = "AWSCloudTrailAclCheck"
            Effect = "Allow"
            Principal = {
                Service = "cloudtrail.amazonaws.com"
            }
            Action = "s3:GetBucketAcl"
            Resource = aws_s3_bucket.centralized_logs.arn
            Condition = {
                StringEquals = {
                    "aws:SourceAccount" = data.aws_caller_identity.current.account_id
                }
            }
        },
        ## ALLOW CLOUDTRAIL TO WRITE LOGS
        {
            Sid = "AWSCloudTrailWrite"
            Effect = "Allow"
            Principal = {
                Service = "cloudtrail.amazonaws.com"
            }
            Action = "s3:PutObject"
            Resource = "${aws_s3_bucket.centralized_logs.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
            Condition = {
                StringEquals = {
                    "s3:x-amz-acl" = "bucket-owner-full-control"
                    "aws:SourceAccount" = data.aws_caller_identity.current.account_id
                    "s3:x-amz-server-side-encryption" = "aws:kms"
                }
            }
        },
        # ENCRYPTION
        ## ENFORCE TLS
        {
            Sid = "DenyInsecureTransport"
            Effect = "Deny"
            Principal = "*"
            Action = "s3:*"
            Resource = [
                aws_s3_bucket.centralized_logs.arn,
                "${aws_s3_bucket.centralized_logs.arn}/*"
            ]
            Condition = {
                Bool = {
                    "aws:SecureTransport" = "false"
                }
            }
        },
        ## ENFORCE KMS ENCRYPTION
        {
            Sid = "DenyUnencryptedUplaods"
            Effect = "Deny"
            Principal = "*"
            Action = "s3:PutObject"
            Resource = "${aws_s3_bucket.centralized_logs.arn}/*"
            Condition = {
                StringNotEquals = {
                    "s3:x-amz-server-side-encryption" = "aws:kms"
                }
            }
        }
    ]
  })
}