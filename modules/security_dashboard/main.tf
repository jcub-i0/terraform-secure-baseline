# SECURITYHUB INSIGHTS
## CRITICAL + HIGH FINDINGS
resource "aws_securityhub_insight" "critical_high" {
  name = "Critical and High Findings"
  group_by_attribute = "SeverityLabel"

  filters {
    severity_label {
      comparison = "EQUALS"
      value = "CRITICAL"
    }

    severity_label {
      comparison = "EQUALS"
      value = "HIGH"
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