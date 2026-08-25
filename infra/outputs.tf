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

output "runtime_arn" {
  description = "ARN of the IAM-protected strict MCP 2026-07-28 runtime."
  value       = aws_bedrockagentcore_agent_runtime.mcp.agent_runtime_arn
}

output "runtime_log_group" {
  description = "CloudWatch log group containing the target-indexing request evidence."
  value       = "/aws/bedrock-agentcore/runtimes/${aws_bedrockagentcore_agent_runtime.mcp.agent_runtime_id}-DEFAULT"
}
