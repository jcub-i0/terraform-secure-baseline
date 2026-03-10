output "firewall_arn" {
  value = aws_networkfirewall_firewall.egress.arn
}

output "firewall_name" {
  value = aws_networkfirewall_firewall.egress.name
}

output "firewall_status" {
  value = aws_networkfirewall_firewall.egress.firewall_status
}

output "sync_states" {
  value = aws_networkfirewall_firewall.egress.firewall_status[0].sync_states
}