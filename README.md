# template-pipelines

Reusable GitHub Actions workflows, called from other repositories via `workflow_call`.

| Workflow | Purpose |
| --- | --- |
| [`terraform.yml`](.github/workflows/terraform.yml) | Terraform CI/CD: fmt, init, validate, plan (with PR comment), optional gated apply |
| [`pre-commit.yml`](.github/workflows/pre-commit.yml) | Runs all pre-commit hooks against the full repository |
| [`release.yml`](.github/workflows/release.yml) | Semver tagging on CD: bumps from conventional commits, pushes the tag, creates a GitHub release |

## Terraform CI/CD

Plans on every run and comments the plan on pull requests. When `apply: true`, the saved plan is applied in a second job, optionally gated behind a GitHub environment's required reviewers.

Authentication is to Azure via OIDC federated credentials — no long-lived secrets. The workflow logs in with `azure/login` and exports the `ARM_*` environment variables so both the `azurerm` provider and backend authenticate with OIDC.

```yaml
name: Terraform

on:
  pull_request:
  push:
    branches:
      - main

jobs:
  terraform:
    uses: jay-withers/template-pipelines/.github/workflows/terraform.yml@main
    with:
      working-directory: terraform
      apply: ${{ github.ref == 'refs/heads/main' }}
      environment: production
      azure-client-id: ${{ vars.AZURE_CLIENT_ID }}
      azure-tenant-id: ${{ vars.AZURE_TENANT_ID }}
      azure-subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}
```

### Setting up Azure OIDC

[`scripts/setup-azure-oidc.sh`](scripts/setup-azure-oidc.sh) bootstraps everything for a calling repository: it creates the app registration and service principal, adds federated credentials (branch, pull requests, and any GitHub environments you pass), assigns a role on the subscription, and sets `AZURE_CLIENT_ID` / `AZURE_TENANT_ID` / `AZURE_SUBSCRIPTION_ID` as Actions variables on the repo. Requires `az`, `gh`, and `jq`, logged in with permissions to create app registrations and role assignments.

```sh
./scripts/setup-azure-oidc.sh -r jay-withers/my-infra -e production
```

### Terraform inputs

| Input | Default | Description |
| --- | --- | --- |
| `working-directory` | `.` | Directory containing the Terraform code |
| `terraform-version` | `1.9.8` | Terraform version to install |
| `apply` | `false` | Run `terraform apply` on the saved plan after a successful plan |
| `environment` | `""` | GitHub environment for the apply job — set required reviewers on it to gate applies |
| `azure-client-id` | required | Azure app registration / managed identity client ID for OIDC |
| `azure-tenant-id` | required | Azure tenant ID |
| `azure-subscription-id` | required | Azure subscription ID |

Notes:

- The plan job needs `pull-requests: write` (PR comments) and `id-token: write` (OIDC); the caller's `GITHUB_TOKEN` must not restrict these below what the reusable workflow requests.
- The plan file is uploaded as a short-lived artifact and applied verbatim, so what was reviewed is what gets applied. Plan files can contain sensitive values — keep this repo's callers private if that matters.
- The Terraform backend is expected to be configured in code (an `azurerm` backend block; `ARM_USE_OIDC=true` is exported so it can use OIDC too).

## Pre-commit CI

Runs `pre-commit run --all-files` with the hook environments cached. The calling repository must contain a `.pre-commit-config.yaml`. Hooks that need extra tooling on the runner (e.g. `terraform-docs`, `tflint`) should install it themselves or use dockerised hooks.

```yaml
name: Pre-commit

on:
  pull_request:
  push:
    branches:
      - main

jobs:
  pre-commit:
    uses: jay-withers/template-pipelines/.github/workflows/pre-commit.yml@main
```

### Pre-commit inputs

| Input | Default | Description |
| --- | --- | --- |
| `python-version` | `3.12` | Python version used to run pre-commit |

## Semver release tagging

On each push to the default branch, computes the next semver from [conventional commits](https://www.conventionalcommits.org/) since the last tag (`fix:` → patch, `feat:` → minor, `BREAKING CHANGE`/`!` → major), pushes the tag, and creates a GitHub release with a generated changelog. Commits with no conventional prefix fall back to `default-bump`.

```yaml
name: Release

on:
  push:
    branches:
      - main

jobs:
  release:
    uses: jay-withers/template-pipelines/.github/workflows/release.yml@main
    with:
      update-major-tag: true
```

Typically chained after the Terraform apply job with `needs:`, so a release is only cut when the deploy succeeds.

### Release inputs

| Input | Default | Description |
| --- | --- | --- |
| `default-bump` | `patch` | Bump when no conventional commit is found (`major`, `minor`, `patch`, or `false` to skip tagging) |
| `release` | `true` | Create a GitHub release for the new tag |
| `update-major-tag` | `false` | Force-move the major tag (e.g. `v1`) to the new release — useful for action/workflow repos |
| `dry-run` | `false` | Compute the next version without tagging |

Outputs `tag` (e.g. `v1.4.2`) and `version` (`1.4.2`) for downstream jobs.

## Repo CI

[`lint.yml`](.github/workflows/lint.yml) runs [actionlint](https://github.com/rhysd/actionlint) against the workflows in this repository on every push and pull request.

## Development

Open the repo in the [dev container](.devcontainer/devcontainer.json) (or locally with `make install`) to get the git hooks set up. Useful targets:

```sh
make install     # install pre-commit and the git hooks
make lint        # actionlint + shellcheck (falls back to docker if not installed)
make pre-commit  # run all pre-commit hooks against the full repo
```

The repo dogfoods its own [pre-commit workflow](.github/workflows/pre-commit.yml) config via [`.pre-commit-config.yaml`](.pre-commit-config.yaml).

## Versioning

Callers should pin to a tag (`@v1`) or commit SHA rather than `@main` once this repo is tagged, so pipeline changes roll out deliberately.
