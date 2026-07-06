.DEFAULT_GOAL := help

.PHONY: help install lint actionlint shellcheck pre-commit protect-branch

BRANCH ?= main
CHECKS ?= pre-commit / Pre-commit

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'

install: ## Install dev tooling and git hooks
	@command -v pre-commit >/dev/null 2>&1 || pip install --user pre-commit || pipx install pre-commit
	pre-commit install

lint: actionlint shellcheck ## Run all linters

actionlint: ## Lint GitHub workflows
	@if command -v actionlint >/dev/null 2>&1; then \
		actionlint -color; \
	else \
		docker run --rm -v "$(CURDIR):/repo" -w /repo rhysd/actionlint:latest -color; \
	fi

shellcheck: ## Lint shell scripts
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck scripts/*.sh; \
	else \
		docker run --rm -v "$(CURDIR):/repo" -w /repo koalaman/shellcheck:stable scripts/*.sh; \
	fi

pre-commit: ## Run all pre-commit hooks against the full repo
	pre-commit run --all-files --show-diff-on-failure

protect-branch: ## Configure repo auto-merge + branch protection ruleset via gh (args: BRANCH, CHECKS)
	./scripts/protect-branch.sh "$(BRANCH)" "$(CHECKS)"
