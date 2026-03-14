########################################
# IAM Role for Maintenance Window task 
########################################

resource "aws_iam_role" "patch_maintenance_window" {
  name = "${var.cloud_name}-patch-mw-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
        {
            Effect = "Allow"
            Principal = {
                Service = "ssm.amazonaws.com"
            }
            Action = "sts:AssumeRole"
        }
    ]
  })

  tags = {
    Name = "PatchMaintenanceWindowRole"
    Terraform = "true"
  }
}