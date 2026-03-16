# SECURITYHUB INSIGHTS
## CRITICAL + HIGH FINDINGS
resource "aws_securityhub_insight" "critical_high" {
  name               = "Critical and High Findings"
  group_by_attribute = "SeverityLabel"

  filters {
    severity_label {
      comparison = "EQUALS"
      value      = "CRITICAL"
    }

    severity_label {
      comparison = "EQUALS"
      value      = "HIGH"
    }

    workflow_status {
      comparison = "NOT_EQUALS"
      value      = "RESOLVED"
    }

    record_state {
      comparison = "EQUALS"
      value      = "ACTIVE"
    }
  }
}

## GUARDDUTY ACTIVE FINDINGS
resource "aws_securityhub_insight" "guardduty_active" {
  name = "Active GuardDuty Findings"
  group_by_attribute = "SeverityLabel"

  filters {
    product_arn {
      comparison = "EQUALS"
      value = "GuardDuty"
    }

    workflow_status {
      comparison = "NOT_EQUALS"
      value = "RESOLVED"
    }

    record_state {
      comparison = "EQUALS"
      value = "ACTIVE"
    }
  }
}