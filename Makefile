SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c

TF := terraform -chdir=infra
TARGET_NAME := strict-runtime

.PHONY: apply destroy fmt init logs validate verify-runtime

init:
	$(TF) init

fmt:
	terraform fmt -recursive

validate: init
	$(TF) validate

# Expected to fail while creating the DEFAULT-mode gateway target.
apply: validate
	$(TF) apply -auto-approve

verify-runtime:
	@payload=$$(mktemp); output=$$(mktemp); \
	trap 'rm -f "$$payload" "$$output"' EXIT; \
	printf '%s' '{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"repro","version":"1.0.0"},"io.modelcontextprotocol/clientCapabilities":{}}}}' > "$$payload"; \
	aws bedrock-agentcore invoke-agent-runtime \
		--region $$(terraform -chdir=infra output -raw aws_region) \
		--agent-runtime-arn "$$($(TF) output -raw runtime_arn)" \
		--qualifier DEFAULT \
		--content-type application/json \
		--accept 'application/json, text/event-stream' \
		--mcp-protocol-version 2026-07-28 \
		--payload "fileb://$$payload" \
		"$$output" >/dev/null; \
	cat "$$output" | jq .

logs:
	aws logs tail "$$($(TF) output -raw runtime_log_group)" --since 10m

destroy:
	@set +e; \
	gateway_id=$$($(TF) output -raw gateway_id 2>/dev/null); \
	region=$$($(TF) output -raw aws_region 2>/dev/null); \
	if [[ -n "$$gateway_id" && -n "$$region" ]]; then \
		for target_id in $$(aws bedrock-agentcore-control list-gateway-targets \
			--region "$$region" --gateway-identifier "$$gateway_id" \
			--query "items[?name=='$(TARGET_NAME)'].targetId" --output text 2>/dev/null); do \
			aws bedrock-agentcore-control delete-gateway-target \
				--region "$$region" --gateway-identifier "$$gateway_id" \
				--target-id "$$target_id" >/dev/null; \
		done; \
		sleep 10; \
	fi; \
	$(TF) state rm aws_bedrockagentcore_gateway_target.runtime >/dev/null 2>&1; \
	set -e; \
	$(TF) destroy -auto-approve
