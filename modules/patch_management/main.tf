# MAINTENANCE WINDOW
resource "aws_ssm_maintenance_window" "patching" {
  name = "${var.cloud_name}-weekly-patching"
  description = "Weekly patch window for Ubuntu EC2 instances"
  schedule = "cron(0 3 ? * SUN *)"
  schedule_timezone = "America/New_York"
  duration = 3
  cutoff = 1
  allow_unassociated_targets = false
  enabled = var.enabled

  tags = {
    Name = "Weekly-Patching"
    Terraform = "true"
  }
}