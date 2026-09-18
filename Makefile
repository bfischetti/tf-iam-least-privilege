.PHONY: init validate plan check test-bad clean

# The good module: plan it and prove the guardrail passes.
init:
	terraform init -input=false

validate:
	terraform validate

plan:
	terraform plan -out tfplan.binary -input=false
	terraform show -json tfplan.binary > tfplan.json

# Run the least-privilege guardrail against the planned IAM. Expected: pass.
check: plan
	conftest test tfplan.json --policy policy

# Prove the guardrail actually catches violations. Expected: conftest FAILS,
# so we invert the exit code and fail the target if the bad plan slips through.
test-bad:
	cd test/insecure-fixture && terraform init -input=false >/dev/null && \
		terraform plan -out bad.binary -input=false >/dev/null && \
		terraform show -json bad.binary > bad.json
	@echo "Running guardrail against the insecure fixture (it must FAIL)..."
	@if conftest test test/insecure-fixture/bad.json --policy policy >/dev/null 2>&1; then \
		echo "REGRESSION: guardrail passed an insecure policy"; exit 1; \
	else \
		echo "OK: guardrail correctly rejected the insecure fixture"; \
	fi

clean:
	rm -f tfplan.binary tfplan.json test/insecure-fixture/bad.binary test/insecure-fixture/bad.json
