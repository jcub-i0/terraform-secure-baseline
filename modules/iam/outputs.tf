output "instance_profile_name" {
  description = "The 'name' attribute of the EC2 IAM Instance Profile"
  value = aws_iam_instance_profile.ec2_profile.name
}