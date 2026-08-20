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

output "firewall_endpoint_ids_by_az" {
  description = "Map of AZ -> Network Firewall endpoint ID"
  value = {
    for s in aws_networkfirewall_firewall.egress.firewall_status[0].sync_states :
    s.availability_zone => s.attachment[0].endpoint_id
  }
}

output "allowed_egress_domains" {
  description = "Domain targets configured on the Network Firewall stateful domain allowlist."
  value       = aws_networkfirewall_rule_group.stateful_domains.rule_group[0].rules_source[0].rules_source_list[0].targets
}
