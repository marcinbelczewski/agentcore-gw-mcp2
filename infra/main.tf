data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/../lambda_function.py"
  output_path = "${path.module}/lambda.zip"
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

resource "aws_iam_role" "lambda" {
  name = "${var.name_prefix}-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_lambda_function" "mcp" {
  function_name    = "${var.name_prefix}-mcp"
  description      = "Strict MCP 2026-07-28-only server for Gateway DYNAMIC listing reproduction."
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.13"
  handler          = "lambda_function.lambda_handler"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  timeout          = 30

  depends_on = [aws_iam_role_policy_attachment.lambda_logs]
}

resource "aws_lambda_function_url" "mcp" {
  function_name      = aws_lambda_function.mcp.function_name
  authorization_type = "AWS_IAM"
  invoke_mode        = "BUFFERED"
}

resource "aws_iam_role" "gateway" {
  name = "${var.name_prefix}-gateway"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "bedrock-agentcore.amazonaws.com"
      }
      Action = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
        ArnLike = {
          "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:bedrock-agentcore:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "gateway" {
  name = "invoke-lambda-target"
  role = aws_iam_role.gateway.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "lambda:InvokeFunction",
        "lambda:InvokeFunctionUrl",
      ]
      Resource = aws_lambda_function.mcp.arn
      Condition = {
        StringEquals = {
          "lambda:FunctionUrlAuthType" = "AWS_IAM"
        }
      }
    }]
  })
}

resource "aws_bedrockagentcore_gateway" "mcp" {
  name            = "${var.name_prefix}-gateway"
  description     = "IAM Gateway allowing only MCP 2026-07-28."
  role_arn        = aws_iam_role.gateway.arn
  protocol_type   = "MCP"
  authorizer_type = "AWS_IAM"
  exception_level = "DEBUG"

  protocol_configuration {
    mcp {
      supported_versions = ["2026-07-28"]
      # Intentionally no session_configuration.
    }
  }

  depends_on = [aws_iam_role_policy.gateway]
}

# Avoid IAM propagation races masking protocol-version behavior.
resource "time_sleep" "iam_propagation" {
  create_duration = "30s"

  depends_on = [
    aws_lambda_function_url.mcp,
    aws_bedrockagentcore_gateway.mcp,
    aws_iam_role_policy.gateway,
  ]
}

# DYNAMIC listing defers capability discovery to request time, so creating
# this target is expected to succeed. The question under test is which MCP
# conversation the Gateway then uses toward a strict 2026-07-28-only
# non-AgentCore URL target when serving client requests.
resource "aws_bedrockagentcore_gateway_target" "lambda" {
  gateway_identifier = aws_bedrockagentcore_gateway.mcp.gateway_id
  name               = "strict-lambda"
  description        = "Strict MCP 2026-07-28 Lambda Function URL in DYNAMIC listing mode."

  credential_provider_configuration {
    gateway_iam_role {
      service = "lambda"
    }
  }

  target_configuration {
    mcp {
      mcp_server {
        endpoint     = aws_lambda_function_url.mcp.function_url
        listing_mode = "DYNAMIC"
      }
    }
  }

  depends_on = [time_sleep.iam_propagation]
}
