data "aws_partition" "current" {}

## IAM ROLE FOR RDS ENHANCED MONITORING
data "aws_iam_policy_document" "rds_enhanced_monitoring_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["monitoring.rds.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "rds_enhanced_monitoring" {
  name               = "${var.name_prefix}-RdsEnhancedMonitoringRole"
  assume_role_policy = data.aws_iam_policy_document.rds_enhanced_monitoring_assume.json

  tags = {
    Name        = "${var.name_prefix}-RdsEnhancedMonitoringRole"
    Environment = var.environment
    Terraform   = "true"
  }
}

resource "aws_iam_role_policy_attachment" "rds_enhanced_monitoring" {
  role       = aws_iam_role.rds_enhanced_monitoring.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}
