variable "aws_region" {
  description = "AWS Region in which to reproduce the issue."
  type        = string
  default     = "eu-west-1"
}

variable "name_prefix" {
  description = "Prefix for the repro resources."
  type        = string
  default     = "agentcore-gw-mcp2-repro"
}
