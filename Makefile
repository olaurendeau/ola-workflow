# Same steps as the CI jobs, so `make check` is the CI.
# Nothing has to be installed on the host: shellcheck runs in its own container.
SHELLCHECK_IMAGE ?= koalaman/shellcheck:v0.11.0
SHELL_FILES := hooks/guard.sh hooks/lib/profile.sh bin/ola-profile \
	tests/run.sh tests/guard.test.sh tests/profile.test.sh \
	scripts/spike/agent-identity.sh

help: ## Shows this help
	@grep -hE '^[a-z-]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/' | expand -t24

lint: ## Runs shellcheck on every shell script (job `lint`)
	docker run --rm -v "$(CURDIR):/mnt" -w /mnt $(SHELLCHECK_IMAGE) --shell=bash --external-sources $(SHELL_FILES)

test: ## Runs the bash test suites (job `tests`)
	tests/run.sh

validate: ## Validates the plugin and marketplace manifests (job `manifests`)
# `validate <dir>` stops at marketplace.json, so the plugin manifest is validated by path too.
	claude plugin validate --strict .
	claude plugin validate --strict .claude-plugin/plugin.json

check: lint test validate ## Everything the CI runs

spike: ## Replays the agent-identity spike and prints the measured values
	scripts/spike/agent-identity.sh

.PHONY: help lint test validate check spike
