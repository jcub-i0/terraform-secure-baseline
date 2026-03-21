# IAM IDENTITY CENTER (SSO) RESOURCES

##########################################
# IAM IDENTITY CENTER - DISCOVER INSTANCE
##########################################

data "aws_ssoadmin_instances" "this" {}

locals {
  instance_arn = tolist(data.aws_ssoadmin_instances.this.arns)[0]
  identity_store_id = tolist(data.aws_ssoadmin_instances.this.identity_store_ids)[0]
}

##########################################
# GROUP LOOKUPS
##########################################

data "aws_identitystore_group" "analysts" {
  identity_store_id = local.identity_store_id

  alternate_identifier {
    unique_attribute {
      attribute_path = "Displayname"
      attribute_value = var.secops_analyst_group_name
    }
  }
}