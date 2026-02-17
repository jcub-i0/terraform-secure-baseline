# CONFIG RULES

## RULE TO DETECT EC2 INSTANCES WITH PUBLIC IP ADDRESSES
resource "aws_config_config_rule" "ec2_no_public_ip" {
  name = "ec2-no-public-ip"

  source {
    owner             = "AWS"
    source_identifier = "EC2_INSTANCE_NO_PUBLIC_IP"
  }
}