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
  name               = "Active GuardDuty Findings"
  group_by_attribute = "SeverityLabel"

  filters {
    product_name {
      comparison = "EQUALS"
      value      = "GuardDuty"
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

## INSPECTOR ACTIVE FINDINGS
resource "aws_securityhub_insight" "inspector_active" {
  name               = "Active Inspector Findings"
  group_by_attribute = "SeverityLabel"

  filters {
    product_name {
      comparison = "EQUALS"
      value      = "Inspector"
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

## EC2 FINDINGS
resource "aws_securityhub_insight" "ec2_findings" {
  name               = "EC2 Findings"
  group_by_attribute = "ResourceId"

  filters {
    product_name {
      comparison = "EQUALS"
      value      = "AwsEc2Instance"
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

## FAILED CONTROLS
resource "aws_securityhub_insight" "failed_controls" {
  name               = "Failed Controls by Standard"
  group_by_attribute = "ComplianceSecurityControlId"

  filters {
    compliance_status {
      comparison = "EQUALS"
      value      = "FAILED"
    }

    record_state {
      comparison = "EQUALS"
      value      = "ACTIVE"
    }
  }
}