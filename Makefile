# Same steps as the CI jobs, so `make check` is the CI.
# Nothing has to be installed on the host: shellcheck runs in its own container.
SHELLCHECK_IMAGE ?= koalaman/shellcheck:v0.11.0
# Derived, not enumerated. The list was written out by hand under a target whose help text
# says "every shell script", and it had stopped being that: `scripts/measure.sh` and
# `scripts/scratch.sh` were missing — the script that could delete the repository and the one
# written to stop it. An enumeration that drifts from the claim above it is the defect this
# repository keeps finding, and a Makefile can ask git instead of remembering.
SHELL_FILES := $(shell git ls-files '*.sh' 'bin/*')

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

spike-artifact: ## Prints how to replay the artifact spike in an interactive session
	scripts/spike/agent-artifact.sh --interactive

.PHONY: help lint test validate check spike spike-artifact
