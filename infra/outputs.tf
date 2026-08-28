output "aws_region" {
  description = "AWS Region containing the repro resources."
  value       = var.aws_region
}

output "gateway_id" {
  description = "Identifier of the IAM-protected AgentCore Gateway."
  value       = aws_bedrockagentcore_gateway.mcp.gateway_id
}

output "gateway_url" {
  description = "MCP endpoint of the IAM-protected AgentCore Gateway."
  value       = aws_bedrockagentcore_gateway.mcp.gateway_url
}

output "lambda_function_url" {
  description = "IAM-protected Function URL of the strict MCP 2026-07-28 Lambda."
  value       = aws_lambda_function_url.mcp.function_url
}

output "lambda_log_group" {
  description = "CloudWatch log group containing the Gateway-to-target request evidence."
  value       = "/aws/lambda/${aws_lambda_function.mcp.function_name}"
}
