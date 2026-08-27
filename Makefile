.DEFAULT_GOAL := help

.PHONY: help install lint actionlint pre-commit

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'

install: ## Install dev tooling and git hooks
	@command -v pre-commit >/dev/null 2>&1 || pip install --user pre-commit || pipx install pre-commit
	pre-commit install

lint: actionlint ## Run all linters

actionlint: ## Lint GitHub workflows
	@if command -v actionlint >/dev/null 2>&1; then \
		actionlint -color; \
	else \
		docker run --rm -v "$(CURDIR):/repo" -w /repo rhysd/actionlint:latest -color; \
	fi

pre-commit: ## Run all pre-commit hooks against the full repo
	pre-commit run --all-files --show-diff-on-failure
