#############################################
# SECURITY SERVICE INTEGRATIONS
#
# Roles and policies used by AWS security
# services to interact with other resources
# in the environment.
#############################################

# EVENTBRIDGE ROLE
resource "aws_iam_role" "eventbridge_putevents_to_secops" {
  name = "${var.name_prefix}-EventBridgePutEventsToSecopsBus"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# ALLOW EVENTBRIDGE TO PUT EVENTS TO SECOPS BUS
resource "aws_iam_role_policy" "eventbridge_putevents_to_secops" {
  role = aws_iam_role.eventbridge_putevents_to_secops.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect   = "Allow"
      Action   = "events:PutEvents"
      Resource = var.secops_event_bus_arn
    }]
  })
}