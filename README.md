# template-pipelines

Reusable GitHub Actions workflows, called from other repositories via `workflow_call`.

| Workflow | Purpose |
| --- | --- |
| [`terraform.yml`](.github/workflows/terraform.yml) | Terraform CI: credential-free init, validate and optional `terraform test` across one or more root modules |
| [`terraform-deploy.yml`](.github/workflows/terraform-deploy.yml) | Terraform CD: OIDC to Azure, plan one root module for one environment, and optionally apply the saved plan |
| [`pre-commit.yml`](.github/workflows/pre-commit.yml) | Runs all pre-commit hooks against the full repository |
| [`python.yml`](.github/workflows/python.yml) | Python CI: runs a project's test suite with uv |
| [`docker.yml`](.github/workflows/docker.yml) | Container images: builds one or more images, optionally pushing them under immutable tags |
| [`release.yml`](.github/workflows/release.yml) | Semver tagging on CD: bumps from conventional commits, pushes the tag, creates a GitHub release |
| [`codeql.yml`](.github/workflows/codeql.yml) | Code scanning: CodeQL static analysis, one job per language, results in the Security tab |

## Terraform CI

Credential-free validation of every root module in the calling repository: `terraform init -backend=false` then `terraform validate`, one matrix leg per directory, plus an optional `terraform test` job for repos whose tests mock their providers.

There is no plan or apply job, deliberately. A plan needs Azure credentials and only succeeds once the configuration's dependencies already exist — root modules resolve each other with data sources, so a plan against a not-yet-applied dependency fails at plan time and reports a CI failure for something that is not a defect. For a credentialled plan, and apply on merge, see [Terraform deploy](#terraform-deploy).

`-backend=false` is what keeps this credential-free: a repo whose `backend.tf` points at a real remote state account still validates on a fresh clone with no Azure auth.

```yaml
name: ci-terraform

on:
  pull_request:
    branches: [main]

permissions:
  contents: read

jobs:
  terraform:
    permissions:
      contents: read
      pull-requests: read
    uses: jay-withers/workflows/.github/workflows/terraform.yml@main
    with:
      directories: '["terraform/management", "terraform/connectivity"]'
```

### Terraform inputs

| Input | Default | Description |
| --- | --- | --- |
| `directories` | `["terraform"]` | JSON array of root-module directories to init and validate, relative to the repo root. One matrix leg each |
| `test-directories` | `[]` | JSON array of directories to run `terraform test` in. Empty skips the test job |
| `runs-on` | `ubuntu-latest` | Runner label for every job |

Notes:

- **The required status check is `<caller job id> / Terraform`** — for the example above, `terraform / Terraform`. A reusable workflow's checks are namespaced by the calling job's id, the same way `pre-commit.yml` reports as `pre-commit / Pre-commit`. Update branch protection when adopting this, or the required check hangs pending forever.
- The caller must grant the calling job `pull-requests: read`; the path filter that decides whether the PR touches Terraform runs inside this workflow.
- Path filtering lives inside this workflow rather than on the caller's trigger, so the workflow always runs and the gate job always reports. A workflow skipped by a top-level paths filter leaves its required check pending and blocks the merge. The filter matches `terraform/**`, `.terraform-version` and `.github/workflows/ci-terraform.yml`.
- The gate job treats *skipped* as success, so a PR touching no Terraform is not blocked.
- **The `changed` output exposes the path filter's verdict**, so a caller that keeps a Terraform job this workflow will not run — a credentialled `plan`, typically — can gate it on the same filter rather than declaring a second `dorny/paths-filter` that drifts. The cost is ordering: `needs:` waits for the whole called workflow, so such a job starts after `validate` finishes instead of beside it.

  ```yaml
    plan:
      needs: terraform
      if: always() && needs.terraform.outputs.changed == 'true'
  ```

  A job gated this way needs its own always-reporting gate before it can be a required check — `<caller job id> / Terraform` covers only what runs *inside* this workflow.
- The Terraform version comes from a `.terraform-version` file (the [tfenv](https://github.com/tfutils/tfenv) convention) — looked up in each directory first, then the repo root. Renovate's built-in `terraform-version` manager (part of `config:recommended`) keeps it bumped.
- `fmt`, TFLint and Checkov are not run here — they belong to `pre-commit.yml`.

## Terraform deploy

Plans one root module against one environment with Azure credentials, and optionally applies the saved plan in the same job. A PR calls it with `apply: false`; a push to `main` calls it with `apply: true`. Apply runs the exact plan printed above it, and is skipped when the plan has no changes.

On a pull request, the plan is posted as a PR comment: one per directory and environment, edited in place on every push, with a one-line summary (`Plan: 1 to add, 0 to change, 0 to destroy.`) and the full plan behind a collapsible section.

Authentication is GitHub OIDC: the identity's federated credentials must trust `repo:<owner>/<repo>:pull_request` for plans and `repo:<owner>/<repo>:ref:refs/heads/main` for applies. Do not run the job in a GitHub Environment — that changes the OIDC subject to `environment:<name>` and the login fails.

```yaml
# Plan on PR (the caller's ci-terraform)
jobs:
  plan:
    permissions:
      id-token: write
      contents: read
      pull-requests: write # the plan comment
    uses: jay-withers/workflows/.github/workflows/terraform-deploy.yml@main
    with:
      environment: dev
      client-id: ${{ vars.AZURE_CLIENT_ID }}
      tenant-id: ${{ vars.AZURE_TENANT_ID }}
      subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}
```

```yaml
# Apply on merge (the caller's cd-terraform)
name: cd-terraform

on:
  push:
    branches: [main]
    paths: ["terraform/**", ".terraform-version"]
  workflow_dispatch:

permissions:
  contents: read

jobs:
  apply:
    permissions:
      id-token: write
      contents: read
    uses: jay-withers/workflows/.github/workflows/terraform-deploy.yml@main
    with:
      environment: dev
      apply: true
      client-id: ${{ vars.AZURE_CLIENT_ID }}
      tenant-id: ${{ vars.AZURE_TENANT_ID }}
      subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}
```

### Terraform deploy inputs

| Input | Default | Description |
| --- | --- | --- |
| `environment` | `dev` | Picks `backends/<environment>.hcl` and `environments/<environment>.tfvars` inside `directory` |
| `directory` | `terraform` | Root-module directory, relative to the repo root |
| `apply` | `false` | Apply the saved plan when it has changes. Refused on `pull_request` |
| `client-id` | (required) | Client ID of the federated Azure identity |
| `tenant-id` | (required) | Entra tenant ID |
| `subscription-id` | (required) | Azure subscription ID |
| `runs-on` | `ubuntu-latest` | Runner label |

Notes:

- The calling job must grant `id-token: write` and `contents: read`, plus `pull-requests: write` on a PR for the plan comment. The job inherits the caller's grant rather than requesting its own, so an apply caller that doesn't grant `pull-requests: write` still runs.
- The check reports as `<caller job id> / Plan (<environment>)` or `/ Apply (<environment>)`.
- Applies share one concurrency group per directory and environment; plans are grouped by ref, so one PR's plan never displaces another's or a pending apply. An in-progress run is never cancelled. Plans wait up to five minutes for the state lock.
- The plan is also written to the run's job summary, truncated at 60,000 bytes like the comment. The job log always has the full plan.
- Plan output is as public as the repo's Actions logs already are. Terraform masks `sensitive` values in both.

## Pre-commit CI

Runs `pre-commit run --all-files` with the hook environments cached. The calling repository must contain a `.pre-commit-config.yaml`.

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

### Terraform hooks

Set `terraform: true` to install the toolchain that Terraform pre-commit hooks (`terraform_fmt`, `terraform_tflint`, `terraform_docs`, `checkov`) expect on the runner — Terraform, TFLint (with plugins initialised), terraform-docs, Checkov, and Node.js. The toolchain is opt-in so non-Terraform repos keep a lean Python-only run.

```yaml
jobs:
  pre-commit:
    uses: jay-withers/template-pipelines/.github/workflows/pre-commit.yml@main
    with:
      terraform: true
```

The Terraform version resolves from the `terraform-version` input, falling back to a `.terraform-version` file, then `latest`. `actionlint` and `gitleaks` need no extra install here — they run as pre-commit-managed hook repos from [`.pre-commit-config.yaml`](.pre-commit-config.yaml).

### Pre-commit inputs

| Input | Default | Description |
| --- | --- | --- |
| `python-version` | `3.12` | Python version used to run pre-commit |
| `terraform` | `false` | Install the Terraform toolchain (Terraform, TFLint, terraform-docs, Checkov, Node) for Terraform hooks |
| `terraform-version` | `""` | Terraform version to install; if empty, read from `.terraform-version`, falling back to `latest` |
| `node-version` | `24` | Node.js version to install when `terraform` is enabled |
| `terraform-docs-version` | `0.24.0` | terraform-docs version to install (without leading `v`) when `terraform` is enabled |
| `checkov-version` | `3.3.6` | Checkov version to install when `terraform` is enabled |
| `tflint-config` | `terraform/.tflint.hcl` | Path to the TFLint config used to initialise plugins when `terraform` is enabled |

## Python CI

Runs a project's test suite with [uv](https://docs.astral.sh/uv/), on the Python version you name.

Linting is not testing. A repo calling `pre-commit.yml` gets ruff, which proves the code parses and is formatted — not that it works. The gap is widest where nobody reads the diff: with Renovate's `autoApprove` a dependency bump reaches `main` unattended, so a release that breaks a library boundary merges green unless something runs the suite.

```yaml
name: ci-python

on:
  pull_request:
    branches: [main]

permissions:
  contents: read
  pull-requests: write  # only needed for coverage-pr-comment

jobs:
  test:
    uses: jay-withers/workflows/.github/workflows/python.yml@main
    with:
      working-directory: apps/investagent
      python-version: "3.14"
      extras: dev
      coverage: investagent
      coverage-pr-comment: true
      postgres: "18-alpine"
```

Notes:

- **The required status check is `<caller job id> / Test`** — for the example above, `test / Test`, the same namespacing `pre-commit.yml` and `terraform.yml` carry. Update branch protection when adopting this, or the required check hangs pending forever.
- **`extras` is the one input that is easy to get wrong.** `uv run` installs dependency *groups* but not *extras*, so a project whose pytest lives in `[project.optional-dependencies]` must name that extra here. Without it the run fails with a bare `error: Failed to spawn: pytest` after a successful-looking install — and it fails only in CI, because locally the extra is already in the developer's `.venv` from whatever `make install` does.
- **Pin `python-version` to the version the project actually ships on**, not the newest release. A suite that passes on 3.13 says nothing about an image built `FROM python:3.14`.
- `locked` defaults to true, so a `pyproject.toml` edited without its lockfile fails here rather than being resolved around silently as it would be on a developer's machine.
- No internal path filter, unlike `terraform.yml`. A Python suite is seconds of runner time where a Terraform matrix is minutes, so filtering buys little — and always running sidesteps the pending-check trap that file documents.
- **`coverage` names the import package, and nothing is gated on the result.** Set it and the table lands in the job summary; add `coverage-pr-comment: true` for a single PR comment kept up to date across pushes. There is no `--cov-fail-under` input on purpose — a threshold set in a shared workflow is a threshold no consuming repo chose, and the cheapest way to meet one is almost always to mock out whatever is uncovered rather than to test it. Coverage that is not gated has to be *seen* instead, which is what the summary and the comment are for.
- **`postgres` runs a real database for integration tests.** Set it to an image tag and the server is up at `localhost:5432` before the suite runs, with its DSN in `POSTGRES_TEST_DSN`. Tests that need it should *skip* when that variable is absent, so the suite still runs on a clone with no Docker — the workflow deliberately does not provide a fallback DSN, because a test silently pointing at the wrong database is worse than a skipped one. It is started with `docker run` rather than a `services:` block, which cannot be made conditional: a service with an empty image is a workflow error, so a `services:` block would impose Postgres on every caller.
- **`pytest-cov` is not a dependency you have to add.** It arrives through `uv run --with`, an ephemeral overlay, so turning coverage on costs a consuming repo no dev extra and no lockfile churn — and `--with` does not invalidate `locked`.
- **`coverage-pr-comment` needs `pull-requests: write` on the caller**, since a reusable workflow cannot grant itself more than its caller holds. Without it the comment logs a warning and the suite still passes, rather than failing a green run over a comment. The same path covers a fork's read-only token.
- **Set `permissions` on the caller.** This workflow declares none of its own, precisely so the comment's `pull-requests: write` is reachable — which means a caller that sets nothing passes down the repository default instead of a read-only token. `contents: read` is the whole requirement without the comment; add `pull-requests: write` with it.

### Python inputs

| Input | Default | Description |
| --- | --- | --- |
| `working-directory` | `.` | Directory holding `pyproject.toml` and `uv.lock` |
| `python-version` | `3.12` | Python version to run the suite on |
| `extras` | `""` | Space-separated optional-dependency extras to install |
| `command` | `pytest` | Command to run under `uv run` |
| `coverage` | `""` | Import package to measure coverage of. Empty disables it. Never gated |
| `coverage-pr-comment` | `false` | Post the coverage table as one self-updating PR comment. Needs `pull-requests: write` on the caller |
| `postgres` | `""` | Postgres image tag to run for the suite. Empty runs none. Exports `POSTGRES_TEST_DSN` |
| `locked` | `true` | Fail if `uv.lock` is out of date with `pyproject.toml` |
| `runs-on` | `ubuntu-latest` | Runner label |

## Container images

Builds every image a repository ships, and optionally pushes them. A pull request calls this with `push: false`; the release calls it with `push: true` and the tags to publish. Nothing else differs between the two, which is the point — kept as separate workflows, the PR build and the release build drift on platform, context and cache scope until a green PR proves very little about the release.

```yaml
name: ci-container-build

on:
  pull_request:
    branches: [main]
    paths:
      - apps/**

permissions:
  contents: read

jobs:
  build:
    uses: jay-withers/workflows/.github/workflows/docker.yml@main
    with:
      images: |
        [{"name": "api", "context": "apps/api"},
         {"name": "dashboard", "context": "apps/dashboard"}]
```

And the publishing half, from a workflow chained after `release.yml`:

```yaml
jobs:
  publish:
    permissions:
      contents: read
      packages: write
    uses: jay-withers/workflows/.github/workflows/docker.yml@main
    with:
      images: '[{"name": "api", "context": "apps/api"}]'
      ref: ${{ inputs.version }}
      push: true
      tags: ${{ inputs.version }}
      tag-with-sha: true
```

Notes:

- **`push: true` needs `packages: write` on the caller.** This workflow declares no `permissions` of its own, for the same reason `python.yml` does not: a called workflow can never hold more than its caller, so pinning `contents: read` here would make `packages: write` unobtainable however the caller was configured. Set `permissions` on every calling job.
- **Set `ref` to the tag you are publishing.** On a `workflow_call`, `github.sha` is the *calling branch's* head rather than the tag, so a release that trusted it would publish the branch under the tag's name. `tag-with-sha` then resolves the short SHA from the checkout, which is the commit that was actually built.
- **No tag is ever `latest`, and none is moved.** Azure Container Apps creates a revision only when the template changes, so re-pushing a moving tag deploys nothing and reports success. Push `vX.Y.Z` and the short SHA, both immutable, and let the deploy pin one.
- **`push` must stay false on a pull request.** A fork's `GITHUB_TOKEN` could not push anyway, and a PR that publishes an image is a supply-chain hole. The cache is shared by image name across both calls, so a release usually reuses the layers its own PR built.
- A push with no tags fails the job rather than building and publishing nothing usable. A build that is not pushing needs no tags at all.
- **First push to a GHCR package needs two things `packages: write` cannot supply.** A new package is private whatever the repository's visibility, so make it public once if anything pulls anonymously; and `GITHUB_TOKEN` can only write to a package *linked* to the repository. A package first pushed by hand is user-scoped and unlinked, and the push fails `denied: permission_denied: write_package` — which reads like a missing permission rather than a missing link. The `org.opencontainers.image.source` label establishes the link, but only from a push that is already allowed, so either push once by hand with the label in place or grant the repository Write under the package's "Manage Actions access".
- `platforms` is one platform by default. A manifest list with a single entry buys nothing, and a runtime that only ever runs amd64 pays for every other architecture in build minutes.

### Docker inputs

| Input | Default | Description |
| --- | --- | --- |
| `images` | *required* | JSON array of `{"name", "context"}` objects. `name` is the last segment of the reference and the cache scope; `context` is the build context. One matrix leg each |
| `ref` | `""` | Git ref to check out. Empty uses the event default. Set to the tag on a release |
| `push` | `false` | Push the images. Keep false on pull requests |
| `tags` | `""` | Whitespace- or newline-separated tag *values* (not full references) applied to every image. Required when pushing |
| `tag-with-sha` | `false` | Also tag with the short SHA of the checked-out commit |
| `registry` | `ghcr.io` | Registry host |
| `image-prefix` | `""` | Path under the registry each name hangs off. Empty uses `owner/repo` |
| `platforms` | `linux/amd64` | Buildx target platforms |
| `summary-note` | `""` | Markdown line appended to the job summary after the pushed references |
| `runs-on` | `ubuntu-latest` | Runner label |

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

## Code scanning

Runs [CodeQL](https://codeql.github.com/) over the repository, one job per language, and uploads the results to the repository's **Security → Code scanning** tab and as pull request annotations.

Static analysis complements DAST rather than replacing it. A DAST scanner can only attack what is reachable from outside — for an app behind a login, the login form. CodeQL reads every code path, including everything behind the login, and traces untrusted input to where it is used, which is where injection and path-traversal bugs are.

```yaml
name: ci-codeql

on:
  pull_request:
    branches: [main]
  push:
    branches: [main]
  schedule:
    - cron: "17 3 * * 1"

permissions:
  contents: read

jobs:
  codeql:
    permissions:
      contents: read
      actions: read
      security-events: write
    uses: jay-withers/workflows/.github/workflows/codeql.yml@<sha> # vX.Y.Z
    with:
      languages: '["python", "actions"]'
```

Notes:

- **Trigger on `push` to `main` as well as pull requests.** Code scanning compares a pull request's results against the default branch's, so a repo that only ever analyses pull requests has no baseline: every alert looks new, and fixed ones are never closed.
- **The weekly `schedule` catches old code with new queries.** CodeQL's query packs grow with each release, and an unchanged repo would otherwise never be re-checked against them.
- **`security-events: write` is required on the caller** to upload results. This workflow declares no permissions of its own, as `python.yml` doesn't, so the caller's grant is the whole token. `actions: read` lets CodeQL read workflow run metadata, which it uses to annotate results.
- **The job is green whatever it finds.** Findings are alerts in the Security tab, not a failed check. To block merges on new alerts, turn on code scanning merge protection in the repository's ruleset. That's a per-repository decision, not one this workflow makes.
- **The status checks are `<caller job id> / Analyze (<language>)`**, one per language: for the example above, `codeql / Analyze (python)` and `codeql / Analyze (actions)`.
- **`actions` is a language too.** It analyses the repository's own workflow files for injection through `${{ }}` expressions, untrusted checkouts in `pull_request_target`, and over-broad tokens. That's worth including in any repo with workflows, which is every repo here.
- Only languages that need no build are supported as-is (`python`, `actions`, `javascript-typescript`, `ruby`). A compiled language would need a `build-mode` input.

### CodeQL inputs

| Input | Default | Description |
| --- | --- | --- |
| `languages` | `'["python", "actions"]'` | JSON array of CodeQL languages, one job each |
| `queries` | `security-extended` | Query suite: `security-extended` or `security-and-quality` |
| `runs-on` | `ubuntu-latest` | Runner label |

## Repo CI

This repo dogfoods its own reusable workflows by calling them with local paths (no `@ref` needed). These callers are prefixed `_self_` to distinguish them from the public reusable workflows — they are internal and not meant to be consumed by other repos:

- [`_self_ci.yml`](.github/workflows/_self_ci.yml) calls [`pre-commit.yml`](.github/workflows/pre-commit.yml) on every push and pull request — the hooks in [`.pre-commit-config.yaml`](.pre-commit-config.yaml) cover actionlint, gitleaks secret scanning and file hygiene.
- [`_self_codeql.yml`](.github/workflows/_self_codeql.yml) calls [`codeql.yml`](.github/workflows/codeql.yml) with `languages: '["actions"]'`, scanning this repo's own workflow files, which are the only code here.
- [`_self_cd.yml`](.github/workflows/_self_cd.yml) calls [`release.yml`](.github/workflows/release.yml) on pushes to `main` with `update-major-tag: true`, so callers can pin to `@v1`.
- Every external action is pinned to a full commit SHA with the version in a trailing comment. A pre-commit hook (`pin-github-actions`) enforces this in CI, and Renovate keeps the pins up to date.
- Dependency updates come from the shared presets in [`renovate`](https://github.com/jay-withers/renovate); [`renovate.json`](renovate.json) just extends them, so policy changes land centrally.

## Development

Open the repo in the [dev container](.devcontainer/devcontainer.json) (or locally with `make install`) to get the git hooks set up. Useful targets:

```sh
make install     # install pre-commit and the git hooks
make lint        # actionlint + shellcheck (falls back to docker if not installed)
make pre-commit  # run all pre-commit hooks against the full repo
```

The same hooks run in CI via the repo's own [pre-commit workflow](.github/workflows/pre-commit.yml).

## Versioning

Callers should pin to a tag (`@v1`) or commit SHA rather than `@main` once this repo is tagged, so pipeline changes roll out deliberately.
