output "admission_gate" {
  description = "Foundation-owned gate references for protected application configuration."

  value = {
    table_arn = aws_dynamodb_table.admission_gate.arn
    cmk_arn   = var.admission_gate_cmk_arn
  }
}