data "archive_file" "runtime" {
  type        = "zip"
  source_file = "${path.module}/../main.py"
  output_path = "${path.module}/runtime.zip"
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  runtime_name = replace(var.name_prefix, "-", "_")
}

resource "aws_s3_bucket" "code" {
  bucket        = "${var.name_prefix}-${data.aws_caller_identity.current.account_id}-${var.aws_region}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "code" {
  bucket = aws_s3_bucket.code.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "code" {
  bucket = aws_s3_bucket.code.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_object" "runtime" {
  bucket = aws_s3_bucket.code.id
  key    = "runtime-${data.archive_file.runtime.output_sha256}.zip"
  source = data.archive_file.runtime.output_path
  etag   = data.archive_file.runtime.output_md5

  depends_on = [
    aws_s3_bucket_server_side_encryption_configuration.code,
  ]
}

resource "aws_iam_role" "runtime" {
  name = "${var.name_prefix}-runtime"

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

resource "aws_iam_role_policy" "runtime" {
  name = "runtime-code-and-logs"
  role = aws_iam_role.runtime.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadRuntimeCode"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = aws_s3_object.runtime.arn
      },
      {
        Sid    = "WriteRuntimeLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams",
          "logs:PutLogEvents",
          "logs:PutResourcePolicy",
        ]
        Resource = "*"
      },
    ]
  })
}

resource "aws_bedrockagentcore_agent_runtime" "mcp" {
  agent_runtime_name = local.runtime_name
  description        = "Strict MCP 2026-07-28-only server for Gateway DEFAULT listing reproduction."
  role_arn           = aws_iam_role.runtime.arn

  agent_runtime_artifact {
    code_configuration {
      entry_point = ["main.py"]
      runtime     = "PYTHON_3_14"

      code {
        s3 {
          bucket = aws_s3_object.runtime.bucket
          prefix = aws_s3_object.runtime.key
        }
      }
    }
  }

  lifecycle_configuration {
    idle_runtime_session_timeout = 60
    max_lifetime                 = 60
  }

  network_configuration {
    network_mode = "PUBLIC"
  }

  protocol_configuration {
    server_protocol = "MCP"
  }

  depends_on = [aws_iam_role_policy.runtime]
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
  name = "invoke-runtime-target"
  role = aws_iam_role.gateway.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "bedrock-agentcore:InvokeAgentRuntime"
      Resource = [
        aws_bedrockagentcore_agent_runtime.mcp.agent_runtime_arn,
        "${aws_bedrockagentcore_agent_runtime.mcp.agent_runtime_arn}/*",
      ]
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

# Avoid IAM propagation races masking the protocol-version failure.
resource "time_sleep" "iam_propagation" {
  create_duration = "30s"

  depends_on = [
    aws_bedrockagentcore_agent_runtime.mcp,
    aws_bedrockagentcore_gateway.mcp,
    aws_iam_role_policy.gateway,
  ]
}

# EXPECTED FAILURE: DEFAULT-mode implicit synchronization sends a legacy
# `initialize` request with MCP-Protocol-Version: 2025-11-25. The target
# accepts only 2026-07-28, returns HTTP 400/-32022, and enters FAILED.
resource "aws_bedrockagentcore_gateway_target" "runtime" {
  gateway_identifier = aws_bedrockagentcore_gateway.mcp.gateway_id
  name               = "strict-runtime"
  description        = "Strict MCP 2026-07-28 runtime in DEFAULT listing mode."

  credential_provider_configuration {
    gateway_iam_role {
      service = "bedrock-agentcore"
    }
  }

  target_configuration {
    mcp {
      mcp_server {
        endpoint     = "https://bedrock-agentcore.${var.aws_region}.amazonaws.com/runtimes/${urlencode(aws_bedrockagentcore_agent_runtime.mcp.agent_runtime_arn)}/invocations?qualifier=DEFAULT"
        listing_mode = "DEFAULT"
      }
    }
  }

  depends_on = [time_sleep.iam_propagation]
}
