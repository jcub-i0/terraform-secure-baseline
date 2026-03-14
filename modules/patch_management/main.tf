# MAINTENANCE WINDOW
resource "aws_ssm_maintenance_window" "patching" {
  name                       = "${var.cloud_name}-weekly-patching"
  description                = "Weekly patch window for Ubuntu EC2 instances"
  schedule                   = "cron(0 3 ? * SUN *)"
  schedule_timezone          = "America/New_York"
  duration                   = 3
  cutoff                     = 1
  allow_unassociated_targets = false
  enabled                    = var.patching_enabled

  tags = {
    Name      = "Weekly-Patching"
    Terraform = "true"
  }
}

# MAINTENANCE WINDOW TARGET
resource "aws_ssm_maintenance_window_target" "patching" {
  name          = "${var.cloud_name}-patch-target"
  window_id     = aws_ssm_maintenance_window.patching.id
  description   = "Instances tagged for weekly patching"
  resource_type = "INSTANCE"

  targets {
    key    = "tag:PatchGroup"
    values = [var.patch_tag_value]
  }
}

# MAINTENANCE WINDOW TASK
resource "aws_ssm_maintenance_window_task" "patching" {
  name             = "${var.cloud_name}-run-patch-baseline"
  window_id        = aws_ssm_maintenance_window.patching.id
  description      = "Run AWS-RunPatch-Baseline Install on tagged instances"
  task_type        = "RUN_COMMAND"
  task_arn         = "AWS-RunPatchBaseline"
  service_role_arn = var.patch_maintenance_window_role_arn
  priority         = 1
  max_concurrency  = "1"
  max_errors       = "1"

  targets {
    key    = "WindowTargetIds"
    values = [aws_ssm_maintenance_window.patching.id]
  }

  task_invocation_parameters {
    run_command_parameters {
      comment = "Weekly OS patching"

      parameter {
        name   = "Operation"
        values = ["Install"]
      }

      parameter {
        name   = "RebootOption"
        values = ["RebootIfNeeded"]
      }
    }
  }
}