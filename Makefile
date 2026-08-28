SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c

TF := terraform -chdir=infra
TARGET_NAME := strict-lambda

# curl --aws-sigv4 needs credentials as user/password plus the optional
# session token header; export-credentials handles every credential source.
define SIGV4_ENV
eval "$$(aws configure export-credentials --format env)"; \
token_header=(); \
if [[ -n "$${AWS_SESSION_TOKEN:-}" ]]; then \
	token_header=(-H "x-amz-security-token: $${AWS_SESSION_TOKEN}"); \
fi
endef

.PHONY: apply destroy fmt init logs validate verify-gateway verify-gateway-default verify-lambda

init:
	$(TF) init

fmt:
	terraform fmt -recursive

validate: init
	$(TF) validate

# DYNAMIC listing defers discovery, so apply is expected to succeed.
apply: validate
	$(TF) apply -auto-approve

# Direct check: the Lambda itself serves strict MCP 2026-07-28.
verify-lambda:
	@$(SIGV4_ENV); \
	region=$$($(TF) output -raw aws_region); \
	url=$$($(TF) output -raw lambda_function_url); \
	curl --fail-with-body -sS "$$url" \
		--aws-sigv4 "aws:amz:$$region:lambda" \
		--user "$$AWS_ACCESS_KEY_ID:$$AWS_SECRET_ACCESS_KEY" \
		"$${token_header[@]}" \
		-H 'Content-Type: application/json' \
		-H 'Accept: application/json, text/event-stream' \
		-H 'MCP-Protocol-Version: 2026-07-28' \
		-H 'Mcp-Method: server/discover' \
		-d '{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"repro","version":"1.0.0"},"io.modelcontextprotocol/clientCapabilities":{}}}}' \
	| jq .

# The experiment: list tools through the Gateway and observe (via `make logs`)
# which MCP conversation the Gateway sends to the strict DYNAMIC URL target.
verify-gateway:
	@$(SIGV4_ENV); \
	region=$$($(TF) output -raw aws_region); \
	url=$$($(TF) output -raw gateway_url); \
	curl --fail-with-body -sS "$$url" \
		--aws-sigv4 "aws:amz:$$region:bedrock-agentcore" \
		--user "$$AWS_ACCESS_KEY_ID:$$AWS_SECRET_ACCESS_KEY" \
		"$${token_header[@]}" \
		-H 'Content-Type: application/json' \
		-H 'Accept: application/json, text/event-stream' \
		-H 'MCP-Protocol-Version: 2026-07-28' \
		-H 'Mcp-Method: tools/list' \
		-d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"repro","version":"1.0.0"},"io.modelcontextprotocol/clientCapabilities":{}}}}' \
	| jq .

# Same experiment against the gateway whose target uses DEFAULT listing mode.
verify-gateway-default:
	@$(SIGV4_ENV); \
	region=$$($(TF) output -raw aws_region); \
	url=$$($(TF) output -raw gateway_default_url); \
	curl --fail-with-body -sS "$$url" \
		--aws-sigv4 "aws:amz:$$region:bedrock-agentcore" \
		--user "$$AWS_ACCESS_KEY_ID:$$AWS_SECRET_ACCESS_KEY" \
		"$${token_header[@]}" \
		-H 'Content-Type: application/json' \
		-H 'Accept: application/json, text/event-stream' \
		-H 'MCP-Protocol-Version: 2026-07-28' \
		-H 'Mcp-Method: tools/list' \
		-d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"repro","version":"1.0.0"},"io.modelcontextprotocol/clientCapabilities":{}}}}' \
	| jq .

logs:
	aws logs tail "$$($(TF) output -raw lambda_log_group)" \
		--region "$$($(TF) output -raw aws_region)" --since 10m --format short

destroy:
	@set +e; \
	region=$$($(TF) output -raw aws_region 2>/dev/null); \
	for gateway_output in gateway_id gateway_default_id; do \
		gateway_id=$$($(TF) output -raw "$$gateway_output" 2>/dev/null); \
		if [[ -n "$$gateway_id" && -n "$$region" ]]; then \
			for target_id in $$(aws bedrock-agentcore-control list-gateway-targets \
				--region "$$region" --gateway-identifier "$$gateway_id" \
				--query "items[?starts_with(name, '$(TARGET_NAME)')].targetId" --output text 2>/dev/null); do \
				aws bedrock-agentcore-control delete-gateway-target \
					--region "$$region" --gateway-identifier "$$gateway_id" \
					--target-id "$$target_id" >/dev/null; \
			done; \
		fi; \
	done; \
	sleep 10; \
	$(TF) state rm aws_bedrockagentcore_gateway_target.lambda >/dev/null 2>&1; \
	$(TF) state rm aws_bedrockagentcore_gateway_target.lambda_default >/dev/null 2>&1; \
	set -e; \
	$(TF) destroy -auto-approve
