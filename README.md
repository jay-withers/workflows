# workflows

Reusable GitHub Actions workflows, called from other repositories via `workflow_call`.

| Workflow | Purpose |
| --- | --- |
| [`terraform.yml`](.github/workflows/terraform.yml) | Terraform CI: credential-free init, validate and optional `terraform test` across one or more root modules |
| [`terraform-deploy.yml`](.github/workflows/terraform-deploy.yml) | Terraform CD: OIDC to Azure, plan one root module for one environment, and optionally apply the saved plan |
| [`terraform-unlock.yml`](.github/workflows/terraform-unlock.yml) | Run by hand: releases a stuck Terraform state lock with `terraform force-unlock`, as the same identity the plan uses |
| [`container-apps-deploy.yml`](.github/workflows/container-apps-deploy.yml) | App CD: OIDC to Azure, then the caller's own `make deploy IMAGE_TAG=<version>` rolls a published image onto its Container Apps workloads |
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

Plans one root module against one environment with Azure credentials, and optionally applies the saved plan in the same job. A PR and a merge call it with `apply: false`; applying is a manual run with `apply: true`. Apply runs the exact plan printed above it, and is skipped when the plan has no changes.

On a pull request, the plan is posted as a PR comment: one per directory and environment, edited in place on every push, with a one-line summary (`Plan: 1 to add, 0 to change, 0 to destroy.`) and the full plan behind a collapsible section.

**Infrastructure changes wait for a human, not for a label.** A PR plan fails only when the plan errors; deletes and replaces are called out in the comment. On merge, call it with `apply: false`: a plan with changes then opens a `terraform-pending` issue (one per directory and environment) with the plan summary and any deletes or replaces. Creating it emails the repo owner, and repo-agent's weekly digest lists the open ones. To apply, run the caller by hand with `apply: true` (`cd-terraform`'s `workflow_dispatch`). That run, or any later plan with no changes, closes the issue. Later merges only refresh the issue body, so it doesn't email on every merge. Needs `issues: write`; without it the step warns.

The job runs in the GitHub environment named by `environment` and reads `AZURE_CLIENT_ID`, `AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID` from that environment's variables. Authentication is GitHub OIDC, and because the job is in an environment, the token's subject is `<repo prefix>:environment:<environment>` for plans and applies alike. The identity needs one federated credential with that subject per environment. Read the repo prefix from `gh api repos/<owner>/<repo>/actions/oidc/customization/sub` (`sub_claim_prefix`): newer repos use immutable subjects such as `repo:owner@123/repo@456`, not `repo:owner/repo`.

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
```

```yaml
# Plan on merge, apply by hand (the caller's cd-terraform)
name: cd-terraform

on:
  push:
    branches: [main]
    paths: ["terraform/**", ".terraform-version"]
  workflow_dispatch:

permissions:
  contents: read

jobs:
  # Plans on merge; applies only when run by hand.
  apply:
    permissions:
      id-token: write
      contents: read
      issues: write # terraform-pending and deploy-failed issues
    uses: jay-withers/workflows/.github/workflows/terraform-deploy.yml@main
    with:
      environment: dev
      apply: ${{ github.event_name == 'workflow_dispatch' }}
```

**Drift is checked nightly, not by a person.** A scheduled caller with `drift: true` runs the same plan and records the result as one `OpsEvents_CL` row (`Kind` `drift`, `Status` `ok`, `drifted`, `pending` or `failed`) through the Logs Ingestion API, using the environment's `EVENTS_INGESTION_ENDPOINT` and `EVENTS_DCR_IMMUTABLE_ID` (set by github-repos for a consumer with `send_events = true`; without them the step is skipped with a notice). It never applies and leaves `terraform-pending` issues alone: the platform's alert on `OpsEvents_CL` is what reports a drifted root. A plan with changes while that directory and environment's `terraform-pending` issue is open records `pending` (v1.24.0+): a merged change waiting for its apply, which the issue already reports, so it doesn't alert as drift. If the issue list can't be read, it stays `drifted`. A drifted plan is still a green run; only a plan that errors, or a failed post, fails it.

```yaml
# Nightly drift check (the caller's schedule-drift)
name: schedule-drift

on:
  schedule:
    - cron: "17 3 * * *"
  workflow_dispatch:

permissions:
  contents: read

jobs:
  drift:
    permissions:
      id-token: write
      contents: read
    uses: jay-withers/workflows/.github/workflows/terraform-deploy.yml@main
    with:
      environment: dev
      drift: true
```

### Terraform deploy inputs

| Input | Default | Description |
| --- | --- | --- |
| `environment` | `dev` | GitHub environment the job runs in, and picks `backends/<environment>.hcl` and `environments/<environment>.tfvars` inside `directory` |
| `github-environment` | `""` | Runs the job in this GitHub environment instead of `environment`, which still names the files and the pending/failed issues. For plans and applies that log in as different identities |
| `environment-files` | `true` | `false` passes neither file: for a root with one deployment, whose backend block and `terraform.tfvars` are complete |
| `directory` | `terraform` | Root-module directory, relative to the repo root |
| `apply` | `false` | Apply the saved plan when it has changes. Refused on `pull_request` |
| `drift` | `false` | Nightly drift check: plan only, record `ok`/`drifted`/`pending`/`failed` as an `OpsEvents_CL` row, never touch `terraform-pending` issues. Refused with `apply` |
| `client-id` | `""` | Overrides the environment's `AZURE_CLIENT_ID` |
| `tenant-id` | `""` | Overrides the environment's `AZURE_TENANT_ID` |
| `subscription-id` | `""` | Overrides the environment's `AZURE_SUBSCRIPTION_ID` |
| `runs-on` | `ubuntu-latest` | Runner label |

Notes:

- Each run shows as a deployment to the environment on the PR or commit, plans included, because that is how GitHub records a job running in an environment. Required reviewers or branch rules on the environment apply to plans too.
- The calling job must grant `id-token: write` and `contents: read`, plus `pull-requests: write` on a PR for the plan comment, and `issues: write` on a push for the pending and failure issues. The job inherits the caller's grant rather than requesting its own, so an apply caller that doesn't grant `pull-requests: write` still runs.
- The check reports as `<caller job id> / Plan (<environment>)` or `/ Apply (<environment>)`.
- Applies share one concurrency group per directory and environment; plans are grouped by ref, so one PR's plan never displaces another's or a pending apply. An in-progress run is never cancelled. Plans wait up to five minutes for the state lock.
- **A failed apply opens an issue** labelled `deploy-failed`, as Container Apps deploy does (one per directory and environment, closed by the next successful apply). Apply callers must grant `issues: write`; without it the step only warns.
- The plan is also written to the run's job summary, truncated at 60,000 bytes like the comment. The job log always has the full plan.
- Plan output is as public as the repo's Actions logs already are. Terraform masks `sensitive` values in both.
- **Every `TF_VAR_*` Actions variable becomes a Terraform input** for plan and apply, whether set on the job's environment, the repository or the owner. GitHub upper-cases variable names, so the part after the prefix is lower-cased: `TF_VAR_ALERT_EMAIL_ADDRESS` sets `var.alert_email_address`, and a list or object takes HCL/JSON syntax (`["…"]`). Use it for values that identify a person or a subscription, which don't belong in a committed tfvars file. They are variables, not secrets, so they show in the log; never use it for a credential.
- **A configuration using the github provider** gets `GITHUB_TOKEN` from a `TF_GITHUB_TOKEN` secret on the job's GitHub environment, for plan and apply. Set it on the environment, never as a repository secret, which any branch's run could read. The calling job must pass `secrets: inherit`: without it the called job sees no secrets, its own environment's included, and the provider runs unauthenticated (`403 API rate limit of 60`).
- **A configuration using the cloudflare provider** gets `CLOUDFLARE_API_TOKEN` from a secret of the same name on the job's GitHub environment, for plan and apply, with the same rules: an environment secret, never a repository one, and `secrets: inherit` on the calling job.
- **Separate plan and apply identities** (github-repos): PR plans run in an environment holding a read-only identity and token, and the push and manual runs pass `github-environment` naming one with a deployment branch policy of `main` only, which holds the privileged ones. Pending and failed issues stay keyed on `environment`, so they don't split in two.

## Terraform unlock

Releases a stuck state lock after a plan or apply died mid-run and left the
state blob leased, so every later plan fails with `Error acquiring the state
lock`. Callers wrap it in a `workflow_dispatch` taking the lock ID that error
prints, and pass the same environment inputs as their `cd-terraform` call:

```yaml
# .github/workflows/manual-terraform-unlock.yml
name: manual-terraform-unlock
on:
  workflow_dispatch:
    inputs:
      lock-id:
        description: Lock ID from the "Error acquiring the state lock" message
        required: true
        type: string
permissions:
  contents: read
jobs:
  unlock:
    permissions:
      id-token: write
      contents: read
      actions: read # the in-progress check
    uses: jay-withers/workflows/.github/workflows/terraform-unlock.yml@<sha> # v1.x.0
    with:
      lock-id: ${{ inputs.lock-id }}
      environment: dev
```

### Terraform unlock inputs

| Input | Default | Description |
| --- | --- | --- |
| `lock-id` | (required) | The UUID from Terraform's lock error. Anything else is refused |
| `environment` | `dev` | GitHub environment the job runs in, and picks `backends/<environment>.hcl` inside `directory` |
| `github-environment` | `""` | Runs the job in this GitHub environment instead of `environment` (github-repos: `apply`) |
| `environment-files` | `true` | `false` inits with the root's own backend block |
| `directory` | `terraform` | Root-module directory, relative to the repo root |
| `runs-on` | `ubuntu-latest` | Runner label |

Notes:

- No new grant: breaking the lease is a write on the state container, which
  the plan identity's Storage Blob Data Contributor already covers.
- **It refuses while another Terraform run is in progress** in the repo (any
  workflow named with `terraform` or `drift`), since force-unlocking under a
  live apply corrupts state. That check needs `actions: read`; without it the
  step warns and carries on.
- Refused on `pull_request`. Only run it once you've confirmed the run that took the lock is dead.

## Container Apps deploy

Rolls a published image tag onto a repo's Azure Container Apps workloads by running the caller's own `make deploy IMAGE_TAG=<version> ENV=<environment>`. The make target stays the single definition of a deploy (which apps and jobs take the image, which env vars ride along, the guard against moving tags), so CI and a local `make deploy` can't drift. This workflow only supplies what the target needs unattended: a checkout of the release tag, Terraform (for `terraform output` against real state) and an `az` login.

Authentication is the same as [Terraform deploy](#terraform-deploy): the job runs in the GitHub environment named by `environment`, reads `AZURE_CLIENT_ID`, `AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID` from its variables, and its OIDC subject is `<repo prefix>:environment:<environment>`. The identity needs whatever `make deploy` touches, typically Contributor on the app's resource group plus read access to the Terraform state.

```yaml
# Deploy after publishing (the caller's cd-publish)
jobs:
  publish:
    # ... docker.yml with push: true and tags: ${{ inputs.version }}

  deploy:
    needs: publish
    permissions:
      id-token: write
      contents: read
      issues: write # the deploy-failed issue
    uses: jay-withers/workflows/.github/workflows/container-apps-deploy.yml@main
    with:
      version: ${{ inputs.version }}
```

### Container Apps deploy inputs

| Input | Default | Description |
| --- | --- | --- |
| `version` | (required) | Image tag to deploy, and the git ref checked out |
| `environment` | `dev` | GitHub environment the job runs in, and the `ENV=` passed to make |
| `target` | `deploy` | Make target to run |
| `smoke-target` | `smoke` | Make target proving the deployed version works. Skipped when the Makefile has no such target; empty disables it |
| `live-target` | `deployed-tag` | Make target printing the live image tag (last line of stdout), recorded before the deploy as the rollback version |
| `rollback` | `true` | On a failed deploy or smoke test, redeploy the recorded version. The run still fails |
| `client-id` | `""` | Overrides the environment's `AZURE_CLIENT_ID` |
| `tenant-id` | `""` | Overrides the environment's `AZURE_TENANT_ID` |
| `subscription-id` | `""` | Overrides the environment's `AZURE_SUBSCRIPTION_ID` |
| `deploy-on-merge` | `renovate` | Which merges deploy without a person: `renovate` (Renovate's releases with no major update; the rest are held) or `all` |
| `run-workflow` | `cd-publish` | The workflow the `deploy-pending` issue says to run by hand with the tag |
| `app` | repo name | Recorded as `App` in the deploy event |
| `verify-images` | `""` | Image references without a tag, whitespace-separated. Each must carry build provenance from `docker.yml` for this repo at `version`, or nothing deploys. Empty skips the check |
| `runs-on` | `ubuntu-latest` | Runner label |

Notes:

- **Provenance is checked before anything changes**, when `verify-images` is set: `gh attestation verify oci://<image>:<version> --bundle-from-oci --repo <this repo> --signer-workflow <owner>/workflows/.github/workflows/docker.yml`. A tag can be moved by anyone with package write; the attestation is signed over the digest by the workflow that built it. The bundle is read from the registry, so the caller grants nothing extra. A failure fails the run before `make deploy`, so it opens a `deploy-failed` issue and records `failed`. A rollback isn't checked, since its image may predate attestations. Needs the images published by `docker.yml` with `attest` on.
- The deploy job starts with [harden-runner](https://github.com/step-security/harden-runner) in **audit** mode (as does Terraform deploy's): it logs every outbound connection without blocking any, as the inventory for an allow-list later.

- The calling job must grant `id-token: write` and `contents: read`. When `cd-publish` is itself called from `cd-tag`, `cd-tag`'s calling job must grant `id-token: write` too: a called workflow never holds more than its caller.
- The target receives `IMAGE_TAG` and `ENV` on the command line. `.terraform-version` is read from the repo root or `terraform/`.
- One deploy runs at a time per repo and environment; a newer pending deploy replaces an older one, and an in-progress deploy is never cancelled. The concurrency group is separate from Terraform deploy's, so a merge that changes both runs them side by side. That's safe while the image and its env vars are under `ignore_changes` in Terraform, as `make deploy` assumes.
- Refused on a `pull_request` event.
- **Only Renovate's merges deploy themselves.** A `gate` job runs first and holds a release when a person authored its commit, when a tracked `uv.lock` moves a package up a major version (a minor, below 1.0) since the previous release, or when an earlier release is already held (a release carries every commit before it). A hold publishes nothing new: the image is already built. It opens one `deploy-pending` issue per environment and app, @-mentioning the repo owner and naming the tag and any major updates. A later hold moves the issue to the newer tag. Running the caller by hand (`cd-publish`'s *Run workflow*) with that tag deploys it, and the issue closes once that deploy succeeds. Re-running a held run deploys too. Majors are found in the lock files because pyproject sets only lower bounds, so most arrive inside Renovate's lock-file maintenance, which Renovate never calls major. It reads the lock files through the API, never checking the release out. The gate fails the run if it can't read them or can't open the issue, rather than deploy unchecked or hold silently. `deploy-on-merge: all` turns the hold off. The deploy event records a held release's deploy as `manual`, with the hold in its lead time.
- **Smoke test and rollback.** A green `make deploy` only means Azure accepted the image: apps that scale to zero can go live on a revision whose container never started. When the Makefile has a `smoke` target, the workflow runs `make deployed-tag ENV=…` first and keeps its last line as the version to fall back to, then `make deploy`, then `make smoke IMAGE_TAG=<version> ENV=…`. If either fails, it deploys and smoke-tests the recorded version, then fails the run anyway; the step summary and the `deploy-failed` issue say whether the rollback held. Both targets live in the caller, like `make deploy`:
  - `deployed-tag` prints the tag currently configured (for example the part after `:` in the app's image) and exits 0, printing nothing on a first deploy.
  - `smoke` exits non-zero unless `IMAGE_TAG` is what's running. For an app, poll its default FQDN until a `/healthz`-style endpoint reports `IMAGE_TAG` and readiness passes, allowing for a cold start. For a job, check its configured image; don't start it, since running a job has side effects.
  - `smoke` runs with `SMOKE_PHASE=release` after the deploy and `SMOKE_PHASE=rollback` after a rollback, so it can skip on a rollback what an older image may predate, or what only slows restoring service (starting a self-check run of each job, for example).
  - Rolling back redeploys an image, nothing else. A release whose data or schema change the previous version can't read must not rely on it.
- **Every run records a deploy event**, whatever its outcome: one row in the platform's `Deployments_CL` table (azure-container-apps), posted through the Logs Ingestion API with the run's own Azure login. Columns: `Repo`, `App`, `Environment`, `Version`, `PreviousVersion` (the recorded live tag), `Outcome` (`success`, `untested` when there's no smoke target, `rolled_back` or `failed`), `Trigger` (`renovate` when the released commit is Renovate's, `redeploy` when the run was started by hand to redeploy an existing tag that wasn't held, else `manual`), `CommitSha`, `RunUrl` and `LeadTimeSec` (commit to live; empty for a redeploy). It needs `EVENTS_INGESTION_ENDPOINT` and `EVENTS_DCR_IMMUTABLE_ID` on the environment and `Monitoring Metrics Publisher` on the events rule, all set by github-repos; without the variables the step is skipped with a notice. A post that fails turns the run red, after the issue step, so it never reads as a failed deploy. The Environments page needs no extra step: a job running in a GitHub environment already records a deployment there.
- **A failed deploy opens an issue** labelled `deploy-failed`, @-mentioning the repo owner and linking the run; a repeat failure comments on it and the next success closes it. GitHub emails a failed run only to whoever triggered it, and Renovate's auto-merges trigger most deploys, so without this nobody hears. The caller must grant `issues: write` (and `cd-tag` too, when it calls `cd-publish`); without it the step only warns.

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
    uses: jay-withers/workflows/.github/workflows/pre-commit.yml@main
```

### Terraform hooks

Set `terraform: true` to install the toolchain that Terraform pre-commit hooks (`terraform_fmt`, `terraform_tflint`, `terraform_docs`, `checkov`) expect on the runner — Terraform, TFLint (with plugins initialised), terraform-docs, Checkov, and Node.js. The toolchain is opt-in so non-Terraform repos keep a lean Python-only run.

```yaml
jobs:
  pre-commit:
    uses: jay-withers/workflows/.github/workflows/pre-commit.yml@main
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
      id-token: write # attestations
      attestations: write
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
- **A push attests each image** (`attest`, on by default): a [build provenance](https://docs.github.com/actions/security-for-github-actions/using-artifact-attestations) attestation over the pushed digest, and, with `scan`, a CycloneDX SBOM from Trivy. Both are signed with the run's OIDC identity and pushed to GitHub's attestation store and the registry. The caller grants `id-token: write` and `attestations: write`, beside `packages: write`. Without `id-token: write` the image still ships, with a warning, and a deploy that verifies it refuses it. Check one by hand with `gh attestation verify oci://<image>:<tag> --owner jay-withers`.
- `platforms` is one platform by default. A manifest list with a single entry buys nothing, and a runtime that only ever runs amd64 pays for every other architecture in build minutes.

### Vulnerability scanning

Every build is scanned with [Trivy](https://trivy.dev/): a pull request build is loaded locally and scanned, a publish is scanned from the registry. Findings of every severity are uploaded to the repo's **Security** tab (code scanning, category `trivy-<image>`), where repo-agent's weekly digest reads them.

A **pull request fails** on `scan-fail-on` severities (CRITICAL and HIGH by default) **that have a fix available**: the one kind of finding a PR can act on, by bumping the base image or the package, and the kind Renovate would otherwise auto-merge. Unfixed findings never block. A **publish never fails** on a finding, because the image is already pushed and failing would only skip deploying whatever else the release carries. Accepted risks go in a `.trivyignore` at the repo root (one CVE ID per line, with a comment saying why).

The caller grants `security-events: write` for the upload. Without it the upload warns and the gate still works. A multi-platform build that doesn't push isn't scanned, since it can't be loaded locally.

**Fixes published after a layer was cached still get in, if the Dockerfile asks.** The layer cache is keyed by instruction, so an `apt-get upgrade` or `apk upgrade` step is reused until its own line or the base digest changes, and a fix published since then is missing: Trivy fails the PR on a "fixable" finding the upgrade step was written to fix (market-agent's curl and libssl3, October 2026). So every build passes `OS_PATCH_DATE`, today's UTC date, as a build arg. A build arg invalidates the cache only from where a stage declares it, so declare it directly before the upgrade step:

```dockerfile
FROM base AS runtime
ARG OS_PATCH_DATE
RUN apt-get update \
    && apt-get upgrade -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*
```

That step, and everything after it, rebuilds once a day; everything above it stays cached. A Dockerfile that doesn't declare the ARG builds exactly as before.

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
| `scan` | `true` | Scan each image with Trivy and upload findings to code scanning (needs `security-events: write`) |
| `scan-fail-on` | `CRITICAL,HIGH` | On a build that doesn't push, fail on these severities when a fix is available. Empty reports only |
| `attest` | `true` | On a push, attest build provenance and (with `scan`) an SBOM. Needs `id-token: write` and `attestations: write` |
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
    uses: jay-withers/workflows/.github/workflows/release.yml@main
    with:
      update-major-tag: true
```

Every repo calls it from `cd-tag` on each merge to `main`, and `cd-tag` hands the new tag to `cd-publish` when app files changed.

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
make lint        # actionlint (falls back to docker if not installed)
make pre-commit  # run all pre-commit hooks against the full repo
```

The same hooks run in CI via the repo's own [pre-commit workflow](.github/workflows/pre-commit.yml).

## Versioning

Callers pin a full commit SHA with the tag as a trailing comment (`@<sha> # v1.22.0`), and Renovate bumps the pin, so a change here rolls out repo by repo as each pin moves. `@v1` and `@main` work but are not used in this estate.
