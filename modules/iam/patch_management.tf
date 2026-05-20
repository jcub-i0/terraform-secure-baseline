########################################
# IAM Role for Maintenance Window task 
########################################

data "aws_iam_policy_document" "patch_maintenance_window_assume_role" {
  statement {
    sid     = "AllowSSMAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ssm.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "patch_maintenance_window" {
  name = "${var.name_prefix}-patch-mw-role"

  assume_role_policy = data.aws_iam_policy_document.patch_maintenance_window_assume_role.json

  tags = {
    Name        = "${var.name_prefix}-PatchMaintenanceWindowRole"
    Terraform   = "true"
    Environment = var.environment
  }
}

resource "aws_iam_role_policy_attachment" "patch_maintenance_window" {
  role       = aws_iam_role.patch_maintenance_window.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonSSMMaintenanceWindowRole"
}