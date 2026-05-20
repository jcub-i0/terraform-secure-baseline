#############################################
# SECURITY SERVICE INTEGRATIONS
#
# Roles and policies used by AWS security
# services to interact with other resources
# in the environment.
#############################################

# IAM ACCESS ANALYZER
resource "aws_accessanalyzer_analyzer" "main" {
  analyzer_name = "${var.name_prefix}-account-access-analyzer"
  type          = "ACCOUNT"

  tags = {
    Terraform = "true"
  }
}

## EVENTBRIDGE TRUST POLICY
data "aws_iam_policy_document" "eventbridge_putevents_to_secops_assume_role" {
  statement {
    sid     = "AllowEventBridgeAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

# EVENTBRIDGE ROLE
resource "aws_iam_role" "eventbridge_putevents_to_secops" {
  name               = "${var.name_prefix}-EventBridgePutEventsToSecopsBus"
  assume_role_policy = data.aws_iam_policy_document.eventbridge_putevents_to_secops_assume_role.json
}

# ALLOW EVENTBRIDGE TO PUT EVENTS TO SECOPS BUS
data "aws_iam_policy_document" "eventbridge_putevents_to_secops" {
  statement {
    sid = "AllowEventBridgePutEventsToSecopsBus"
    effect = "Allow"
    actions = ["events:PutEvents"]

    resources = [var.secops_event_bus_arn]
  }
}

resource "aws_iam_role_policy" "eventbridge_putevents_to_secops" {
  role = aws_iam_role.eventbridge_putevents_to_secops.id
  policy = data.aws_iam_policy_document.eventbridge_putevents_to_secops.json
}