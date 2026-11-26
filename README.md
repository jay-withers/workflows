# workflows

Reusable GitHub Actions workflows, called from other repositories via `workflow_call`.

| Workflow | Purpose |
| --- | --- |
| [`terraform.yml`](.github/workflows/terraform.yml) | Terraform CI: credential-free init, validate and optional `terraform test` across one or more root modules |
| [`terraform-deploy.yml`](.github/workflows/terraform-deploy.yml) | Terraform CD: OIDC to Azure (or Google Cloud), plan one root module for one environment, and optionally apply the saved plan |
| [`terraform-unlock.yml`](.github/workflows/terraform-unlock.yml) | Run by hand: releases a stuck Terraform state lock with `terraform force-unlock`, as the same identity the plan uses |
| [`container-apps-deploy.yml`](.github/workflows/container-apps-deploy.yml) | App CD: OIDC to Azure, then the caller's own `make deploy IMAGE_TAG=<version>` rolls a published image onto its Container Apps workloads |
| [`pre-commit.yml`](.github/workflows/pre-commit.yml) | Runs all pre-commit hooks against the full repository |
| [`python.yml`](.github/workflows/python.yml) | Python CI: runs a project's test suite with uv |
| [`go.yml`](.github/workflows/go.yml) | Go CI: runs a module's test suite, with gofmt, golangci-lint, `go vet`, a tidy check and optional coverage floors |
| [`dotnet.yml`](.github/workflows/dotnet.yml) | .NET CI: builds a solution with warnings as errors and runs its suite on Microsoft.Testing.Platform, with `dotnet format`, a lock-file check and optional coverage floors |
| [`docker.yml`](.github/workflows/docker.yml) | Container images: builds one or more images, optionally pushing them under immutable tags |
| [`release.yml`](.github/workflows/release.yml) | Semver tagging on CD: bumps from conventional commits, pushes the tag, creates a GitHub release |
| [`codeql.yml`](.github/workflows/codeql.yml) | Code scanning: CodeQL static analysis, one job per language, results in the Security tab |

## Toolchain from mise

(v1.26.0+) A repo with a `mise.toml` (or `.mise.toml`) at its root gets its tools from it in `terraform.yml`, `terraform-deploy.yml`, `terraform-unlock.yml`, `pre-commit.yml`, `python.yml` and (v1.26.1+, Terraform only) `container-apps-deploy.yml`: each job runs [`jdx/mise-action`](https://github.com/jdx/mise-action) (tools cached between runs) and skips its own setup steps. The same file pins the tools on a developer's machine, so CI runs what you run. With a `mise.lock` alongside, mise installs with `--locked`, checking every download against the recorded checksum.

What each workflow then needs from `mise.toml`, failing with an error naming the tool when it is missing:

| Workflow | Must list | Ignored inputs |
| --- | --- | --- |
| `terraform.yml`, `terraform-deploy.yml`, `terraform-unlock.yml`, `container-apps-deploy.yml` (v1.26.1+) | `terraform` (replaces `.terraform-version`) | none |
| `pre-commit.yml` | `pre-commit`, plus whatever your hooks call: with `terraform: true`, `terraform`, `tflint`, `terraform-docs` and `checkov` | `python-version`, `node-version`, `terraform-version`, `terraform-docs-version`, `checkov-version` |
| `python.yml` | `uv`, and `python` to choose the interpreter (exported as `UV_PYTHON`; without it uv picks one itself) | `python-version` |
| `go.yml` (v1.33.0+) | `go`, plus `golangci-lint` while `lint` is on (v1.34.0+), in any mise config from `working-directory` up to the root. There is no fallback: without one the job fails | none |
| `node.yml` (v1.36.0+) | `node` (npm comes with it), in any mise config from `working-directory` up to the root. There is no fallback: without one the job fails | none |
| `dotnet.yml` (v1.37.0+) | `dotnet` (the SDK, 10 or later), in any mise config from `working-directory` up to the root. There is no fallback: without one the job fails | none |

`terraform.yml`'s change filter counts `mise.toml` as a Terraform change (v1.26.1+), so a Terraform bump there is validated. `tflint --init` still runs with `terraform: true`, authenticated with the job's token (v1.31.1+), so a hosted runner's shared anonymous GitHub API limit can't fail it. A repo without `mise.toml` sees no change. Renovate's shared `mise` preset keeps the versions current.

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
- The Terraform version comes from `mise.toml` when the repo has one (see [Toolchain from mise](#toolchain-from-mise)), otherwise from a `.terraform-version` file (the [tfenv](https://github.com/tfutils/tfenv) convention), looked up in each directory first, then the repo root. Renovate keeps either bumped.
- `fmt`, TFLint and Checkov are not run here — they belong to `pre-commit.yml`.

## Terraform deploy

Plans one root module against one environment with Azure credentials (or, with `cloud: gcp`, Google Cloud ones), and optionally applies the saved plan in the same job. A PR and a merge call it with `apply: false`; applying is a manual run with `apply: true`. Apply runs the exact plan printed above it, and is skipped when the plan has no changes.

On a pull request, the plan is posted as a PR comment: one per directory and environment, edited in place on every push, with a one-line summary (`Plan: 1 to add, 0 to change, 0 to destroy.`) and the full plan behind a collapsible section.

**Infrastructure changes wait for a human, not for a label.** A PR plan fails only when the plan errors; deletes and replaces are called out in the comment. On merge, call it with `apply: false`: a plan with changes then opens a `terraform-pending` issue (one per directory and environment) with the plan summary and any deletes or replaces. Creating it emails the repo owner, and repo-agent's weekly digest lists the open ones. To apply, run the caller by hand with `apply: true` (`cd-terraform`'s `workflow_dispatch`). That run, or any later plan with no changes, closes the issue. Later merges only refresh the issue body, so it doesn't email on every merge. Needs `issues: write`; without it the step warns.

The job runs in the GitHub environment named by `environment` and reads `AZURE_CLIENT_ID`, `AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID` from that environment's variables. Authentication is GitHub OIDC, and because the job is in an environment, the token's subject is `<repo prefix>:environment:<environment>` for plans and applies alike. The identity needs one federated credential with that subject per environment. Read the repo prefix from `gh api repos/<owner>/<repo>/actions/oidc/customization/sub` (`sub_claim_prefix`): newer repos use immutable subjects such as `repo:owner@123/repo@456`, not `repo:owner/repo`.

**Google Cloud** (v1.32.0+): with `cloud: gcp` the same GitHub OIDC token is exchanged for Google credentials through Workload Identity Federation ([`google-github-actions/auth`](https://github.com/google-github-actions/auth)), from the environment's `GCP_WORKLOAD_IDENTITY_PROVIDER` (the provider's full name) and, optionally, `GCP_SERVICE_ACCOUNT`. With a service account, its `roles/iam.workloadIdentityUser` binding must name the job's subject (`principal://iam.googleapis.com/projects/<project number>/locations/global/workloadIdentityPools/<pool>/subject/<repo prefix>:environment:<environment>`); without one, the roles are granted to that `principal://` directly. Nothing else changes: same environments, same `id-token: write`, and a `gcs` backend in `backends/<environment>.hcl` or the root's own backend block. The drift event is Azure-only, so a GCP drift check writes its status to the job summary and warns when it finds drift.

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
    paths: ["terraform/**", "mise.toml", ".terraform-version"]
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
| `cloud` | `azure` | `gcp` (v1.32.0+) signs in to Google Cloud through Workload Identity Federation instead of Azure |
| `workload-identity-provider` | `""` | With `cloud: gcp`, overrides the environment's `GCP_WORKLOAD_IDENTITY_PROVIDER` |
| `service-account` | `""` | With `cloud: gcp`, overrides the environment's `GCP_SERVICE_ACCOUNT`. Neither set uses the federated identity directly |
| `client-id` | `""` | Overrides the environment's `AZURE_CLIENT_ID` |
| `tenant-id` | `""` | Overrides the environment's `AZURE_TENANT_ID` |
| `subscription-id` | `""` | Overrides the environment's `AZURE_SUBSCRIPTION_ID` |
| `runs-on` | `ubuntu-latest` | Runner label |

Output: `has-changes`, `"true"` when the plan had changes.

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
- **A privileged, main-only environment** (github-repos, azure-landingzone): their merge plans, manual applies and drift checks pass `environment: dev` with `github-environment: apply`, an environment with a deployment branch policy of `main` only that holds the privileged identity and token. Their PRs get no credentialled plan at all. Pending and failed issues stay keyed on `environment`, so they don't split in two.

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
| `cloud` | `azure` | `gcp` (v1.32.0+), as in Terraform deploy |
| `workload-identity-provider` | `""` | With `cloud: gcp`, overrides the environment's `GCP_WORKLOAD_IDENTITY_PROVIDER` |
| `service-account` | `""` | With `cloud: gcp`, overrides the environment's `GCP_SERVICE_ACCOUNT` |
| `runs-on` | `ubuntu-latest` | Runner label |

Notes:

- No new grant: breaking the lease is a write on the state container, which
  the plan identity's Storage Blob Data Contributor already covers. On GCP,
  the lock is an object beside the state, under the same prefix grant.
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
| `browser-check` | `false` | (v1.30.0+) Installs uv and Chromium before the deploy, then passes `SMOKE_BROWSER=1` to the smoke target, so `scripts/smoke.sh` also loads each app's home page in Chromium: a 200 with no console error (a failed favicon load aside), or the release rolls back. Unauthenticated; skipped on a rollback. Warns if the smoke target ran no browser check (an old copy of smoke.sh) |
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
- The target receives `IMAGE_TAG` and `ENV` on the command line. Terraform comes from `mise.toml` when the deployed tag has one (v1.26.1+), else from `.terraform-version` in the repo root or `terraform/`.
- One deploy runs at a time per repo and environment; a newer pending deploy replaces an older one, and an in-progress deploy is never cancelled. The concurrency group is separate from Terraform deploy's, so a merge that changes both runs them side by side. That's safe while the image and its env vars are under `ignore_changes` in Terraform, as `make deploy` assumes.
- Refused on a `pull_request` event.
- **Only Renovate's merges deploy themselves.** A `gate` job runs first and holds a release when a person authored its commit, when a tracked `uv.lock` moves a package up a major version (a minor, below 1.0) since the previous release, or when an earlier release is already held (a release carries every commit before it). A hold publishes nothing new: the image is already built. It opens one `deploy-pending` issue per environment and app, @-mentioning the repo owner and naming the tag and any major updates. A later hold moves the issue to the newer tag. Running the caller by hand (`cd-publish`'s *Run workflow*) with that tag, or any later tag that contains it (v1.28.5+), deploys it, and the issue closes once that deploy succeeds. Re-running a held run deploys too. Majors are found in the lock files because pyproject sets only lower bounds, so most arrive inside Renovate's lock-file maintenance, which Renovate never calls major. It reads the lock files through the API, never checking the release out. The gate fails the run if it can't read them or can't open the issue, rather than deploy unchecked or hold silently. `deploy-on-merge: all` turns the hold off. The deploy event records a held release's deploy as `manual`, with the hold in its lead time.
- **Smoke test and rollback.** A green `make deploy` only means Azure accepted the image: apps that scale to zero can go live on a revision whose container never started. When the Makefile has a `smoke` target, the workflow runs `make deployed-tag ENV=…` first and keeps its last line as the version to fall back to, then `make deploy`, then `make smoke IMAGE_TAG=<version> ENV=…`. If either fails, it deploys and smoke-tests the recorded version, then fails the run anyway; the step summary and the `deploy-failed` issue say whether the rollback held. Both targets live in the caller, like `make deploy`:
  - `deployed-tag` prints the tag currently configured (for example the part after `:` in the app's image) and exits 0, printing nothing on a first deploy.
  - `smoke` exits non-zero unless `IMAGE_TAG` is what's running. For an app, poll its default FQDN until a `/healthz`-style endpoint reports `IMAGE_TAG` and readiness passes, allowing for a cold start. For a job, check its configured image; don't start it, since running a job has side effects.
  - `smoke` runs with `SMOKE_PHASE=release` after the deploy and `SMOKE_PHASE=rollback` after a rollback, so it can skip on a rollback what an older image may predate, or what only slows restoring service (starting a self-check run of each job, for example).
  - **(v1.30.0+) Use this repo's [`scripts/smoke.sh`](scripts/smoke.sh)** rather than a copy: it implements exactly the above (`smoke.sh <tag> <resource-group> <image-without-tag> app:<name>... job:<name>...`, with a `selfcheck` run of each job). Fetch it in the `smoke` target at the commit your cd-publish pins this workflow to, so CI and a local `make smoke` run the same version and Renovate's pin bump moves it:

    ```make
    WORKFLOWS_SHA = $(shell sed -n 's|.*container-apps-deploy\.yml@\([0-9a-f]\{40\}\).*|\1|p' .github/workflows/cd-publish.yml | head -n 1)
    SMOKE_SH_URL = https://raw.githubusercontent.com/jay-withers/workflows/$(WORKFLOWS_SHA)/scripts/smoke.sh

    smoke:
    	@[ -n "$(WORKFLOWS_SHA)" ] || { echo "smoke: no container-apps-deploy.yml@<sha> pin in cd-publish.yml" >&2; exit 1; }
    	@script="$$(mktemp)"; trap 'rm -f "$$script"' EXIT; \
    	curl -fsSL --retry 3 -o "$$script" "$(SMOKE_SH_URL)" || { echo "smoke: can't fetch $(SMOKE_SH_URL)" >&2; exit 1; }; \
    	bash "$$script" $(IMAGE_TAG) <resource-group> <image-without-tag> app:<name> job:<name>
    ```

    With `SMOKE_BROWSER=1` (`browser-check: true`) it also loads each app's `/` in Chromium (Playwright, pinned in this workflow and in the script, both bumped by Renovate) once `/readyz` passes, and fails on anything but a 200 or on any console error. For a passcode-gated app that is the login page under the real deployed headers, so a broken template or a CSP block rolls back. It never signs in, so no app secret reaches CI.
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
      coverage-min: "90"
      diff-coverage: "90"
      lint: true
      typecheck: mypy
      postgres: "18-alpine"
```

Notes:

- **The required status check is `<caller job id> / Test`** — for the example above, `test / Test`, the same namespacing `pre-commit.yml` and `terraform.yml` carry. Update branch protection when adopting this, or the required check hangs pending forever.
- **`extras` is the one input that is easy to get wrong.** `uv run` installs dependency *groups* but not *extras*, so a project whose pytest lives in `[project.optional-dependencies]` must name that extra here. Without it the run fails with a bare `error: Failed to spawn: pytest` after a successful-looking install — and it fails only in CI, because locally the extra is already in the developer's `.venv` from whatever `make install` does.
- **Pin `python-version` to the version the project actually ships on**, not the newest release. A suite that passes on 3.13 says nothing about an image built `FROM python:3.14`.
- `locked` defaults to true, so a `pyproject.toml` edited without its lockfile fails here rather than being resolved around silently as it would be on a developer's machine.
- No internal path filter, unlike `terraform.yml`. A Python suite is seconds of runner time where a Terraform matrix is minutes, so filtering buys little — and always running sidesteps the pending-check trap that file documents.
- **`coverage` names the import package.** Set it and the table lands in the job summary; add `coverage-pr-comment: true` for a single PR comment kept up to date across pushes.
- **`coverage-min` is a floor on the total (v1.34.0+).** The job fails when the `coverage` package's total is under it, by `coverage report --fail-under`, so the rounding matches the table. It is checked after a passing suite on every event, so `main` is held to it as well as pull requests. A total floor can fail a change for old code it never touched, so set it at or below every repo's current total before turning it on, and review the tests a PR adds to clear it: a test that only asserts a mock still counts.
- **`diff-coverage` gates the pull request's own lines (v1.28.0+).** Set it to a percentage and the job fails when less than that share of the lines the PR changes in the `coverage` package are run by the suite. The threshold is the caller's choice, nothing is gated by default, a PR that changes no measured code passes, and the uncovered lines are listed in the summary and the coverage comment. On the diff, the cheapest way to pass is usually to test the code just written, but a mock that only asserts itself still counts as covered, so review the tests, not just the number. It needs `coverage`, and runs only on `pull_request` after a passing suite.
- **`lint: true` runs ruff after the suite (v1.34.0+)**: `ruff check` (findings annotated on the PR) and `ruff format --check`, from `working-directory`, under `uv run` with the same `extras` and `locked`. Ruff comes from the project's locked dev dependencies, so it is the version and config the repo's `make lint` uses; the job fails naming the fix when the environment has none. Both commands run before the step fails, and it runs even when a test failed, so one push reports everything. It defaults to off so existing callers see no change; ruff in pre-commit keeps working alongside it.
- **`typecheck` runs a type checker after the suite (v1.28.0+)**, under `uv run` with the same `extras` and `locked`, so it uses the version the project pins and its config, the same as the repo's `make typecheck`. It runs even when a test failed, so one push reports both.
- **`postgres` runs a real database for integration tests.** Set it to an image tag and the server is up at `localhost:5432` before the suite runs, with its DSN in `POSTGRES_TEST_DSN`. Tests that need it should *skip* when that variable is absent, so the suite still runs on a clone with no Docker — the workflow deliberately does not provide a fallback DSN, because a test silently pointing at the wrong database is worse than a skipped one. It is started with `docker run` rather than a `services:` block, which cannot be made conditional: a service with an empty image is a workflow error, so a `services:` block would impose Postgres on every caller.
- **`playwright: true` runs browser tests inside `test / Test`.** Playwright comes from the project's locked dependencies (`pytest-playwright` in the dev extra), so its version is the project's, and the browser download is cached by that version. Only Chromium is installed. Write the browser tests to skip when Chromium is missing on a developer's machine but fail when `CI` is set, or a broken install would pass as skipped. jay-withers/appkit's `appkit.testing.require_browser` does exactly that.
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
| `coverage` | `""` | Import package to measure coverage of. Empty disables it |
| `coverage-min` | `""` | (v1.34.0+) Minimum total % of `coverage` the suite must run. Empty gates nothing. Needs `coverage` |
| `diff-coverage` | `""` | Minimum % of the PR's changed lines in `coverage` the suite must run. Empty gates nothing. Needs `coverage` |
| `typecheck` | `""` | Type-check command to run under `uv run` after the suite, e.g. `mypy`. Empty skips it |
| `lint` | `false` | (v1.34.0+) Run `ruff check` and `ruff format --check` under `uv run` after the suite |
| `coverage-pr-comment` | `false` | Post the coverage table as one self-updating PR comment. Needs `pull-requests: write` on the caller |
| `postgres` | `""` | Postgres image tag to run for the suite. Empty runs none. Exports `POSTGRES_TEST_DSN` |
| `playwright` | `false` | (v1.29.0+) Install Playwright's Chromium, cached per version, with its system libraries before the suite |
| `locked` | `true` | Fail if `uv.lock` is out of date with `pyproject.toml` |
| `runs-on` | `ubuntu-latest` | Runner label |

## Go CI

(v1.33.0+) Runs a Go module's test suite on the Go its `mise.toml` pins: `go mod verify`, a tidy check, `go test` with the race detector, then `go vet`, gofmt and golangci-lint (v1.34.0+). Shaped like [Python CI](#python-ci) on purpose, so a Go repo carries the same required check and the same gates.

```yaml
name: ci-go

on:
  pull_request:
    branches: [main]

permissions:
  contents: read
  pull-requests: write  # only needed for coverage-pr-comment

jobs:
  test:
    uses: jay-withers/workflows/.github/workflows/go.yml@main
    with:
      coverage: true
      coverage-pr-comment: true
      coverage-min: "90"
      diff-coverage: "90"
```

Notes:

- **The required status check is `<caller job id> / Test`**, the same as `python.yml`'s, so a repo moving from Python to Go keeps `test / Test` and its branch protection needs no change.
- **Go comes from `mise.toml` and nowhere else.** There is no `go-version` input and no `setup-go` fallback, so the version is pinned in one place, the same file a developer's machine reads. mise runs from `working-directory`, so it reads every config from there up to the root, and the job fails naming the fix when none pins `go`. mise's Go goes first on `PATH`, ahead of any Go the runner image has. With a `mise.lock` beside the config, mise installs with `--locked`.
- **`GOTOOLCHAIN=local` for the whole job.** Go's default (`auto`) quietly downloads and runs a newer toolchain when `go.mod`'s `go` or `toolchain` line asks for one, which would make the mise pin decorative. With `local`, a `go.mod` that needs a newer Go than `mise.toml` pins fails with both versions named. Bump the two together.
- **`format` and `lint` are on by default (v1.34.0+)**, so `test / Test` alone says the code is formatted, lint-clean and working. `format` fails when `gofmt` would change a tracked `.go` file (`vendor/` excepted) and prints the diff. `lint` runs `golangci-lint run` over `packages`, with the module's `.golangci.yml` if it has one. golangci-lint comes from the mise config, like Go, so add it there (`mise use golangci-lint@<version>`) or set `lint: false`. Both run after the suite, pass or fail, as `vet` does, so one push reports every finding. A repo can still run the same tools from pre-commit for fast local feedback. **Pin a golangci-lint built with a Go at least as new as `go.mod`'s `go` line**, or it refuses to analyse the module; bump the two together (golangci-lint 2.15.0 handles Go 1.27).
- **`tidy` (default on) fails when `go mod tidy` would change `go.mod` or `go.sum`**, the counterpart of `python.yml`'s `locked`. It uses `go mod tidy -diff`, so it needs Go 1.23+. `go mod verify` always runs, checking every downloaded module against `go.sum`.
- **`race` (default on) needs cgo**, which the runner has. The shipped binary can still be built with `CGO_ENABLED=0`.
- **`coverage: true` measures across packages** (`-coverpkg` set to `packages`), so a test in one package counts for the code it runs in another. The total and a per-function listing land in the job summary, and `coverage-pr-comment: true` (which needs `coverage: true`, or the job fails at its first step) posts them as one PR comment kept up to date across pushes. The total is gated only when `coverage-min` is set.
- **`coverage-min` is a floor on the total (v1.34.0+)**: the job fails when `go tool cover`'s total statement coverage is under it. It needs `coverage: true` and is checked after a passing suite on every event, so `main` is held to it as well as pull requests.
- **`diff-coverage` gates the pull request's own lines**, exactly as in `python.yml`. The profile is converted to Cobertura with `gocover-cobertura` and checked by the same pinned `diff-cover`, against `HEAD^1`, on `pull_request` after a passing suite. It needs `coverage: true`. Both tool pins are kept current by regex managers in [`renovate.json`](renovate.json).
- **`vet` runs `go vet` after the suite**, even when a test failed, so one push reports both.
- **Permissions:** `contents: read`, plus `pull-requests: write` for the comment. Without it the comment logs a warning and the suite still passes. The workflow declares no permissions of its own, so set them on the caller.

### Go inputs

| Input | Default | Description |
| --- | --- | --- |
| `working-directory` | `.` | Directory holding `go.mod` |
| `packages` | `./...` | Space-separated package patterns to test, vet and measure |
| `race` | `true` | Run the suite with `-race` |
| `vet` | `true` | Run `go vet` over `packages` after the suite |
| `format` | `true` | (v1.34.0+) Fail if `gofmt` would change a tracked `.go` file |
| `lint` | `true` | (v1.34.0+) Run `golangci-lint run` over `packages`. Needs `golangci-lint` in the mise config |
| `tidy` | `true` | Fail if `go mod tidy` would change `go.mod` or `go.sum` (Go 1.23+) |
| `coverage` | `false` | Measure coverage of `packages`. Reported; gated only by the two inputs below |
| `coverage-min` | `""` | (v1.34.0+) Minimum total statement coverage. Empty gates nothing. Needs `coverage` |
| `diff-coverage` | `""` | Minimum % of the PR's changed lines the suite must run. Empty gates nothing. Needs `coverage` |
| `coverage-pr-comment` | `false` | Post the coverage report as one self-updating PR comment. Needs `coverage` and `pull-requests: write` on the caller |
| `runs-on` | `ubuntu-latest` | Runner label |

## Node CI

(v1.36.0+) Runs a Node/TypeScript package's checks and test suite on the Node its `mise.toml` pins: `npm ci`, `npm audit signatures`, then the package's own `test` (or `test:coverage`), `typecheck`, `lint` and `format:check` scripts. Shaped like [Python CI](#python-ci) and [Go CI](#go-ci) on purpose, so a Node repo carries the same required check and the same gates.

```yaml
name: ci-node

on:
  pull_request:
    branches: [main]

permissions:
  contents: read
  pull-requests: write  # only needed for coverage-pr-comment

jobs:
  test:
    uses: jay-withers/workflows/.github/workflows/node.yml@main
    with:
      coverage: true
      coverage-min: "90"
      diff-coverage: "90"
```

The package needs these scripts in `package.json` (each check can be switched off with its input). [`tests/node`](tests/node) is a working example with vitest, TypeScript, ESLint and Prettier:

```json
"scripts": {
  "typecheck": "tsc --noEmit",
  "lint": "eslint .",
  "format:check": "prettier --check .",
  "test": "vitest run",
  "test:coverage": "vitest run --coverage"
}
```

Notes:

- **The required status check is `<caller job id> / Test`**, the same as `python.yml`'s and `go.yml`'s, so a repo moving from Python to TypeScript keeps `test / Test` and its branch protection needs no change.
- **Node comes from `mise.toml` and nowhere else**, as Go does for `go.yml`: no `node-version` input and no `setup-node` fallback. mise runs from `working-directory`, its Node goes first on `PATH` ahead of the runner image's, and the job fails naming the fix when no config pins `node`. npm is the one bundled with that Node.
- **The checks are the package's own scripts**, not tools named in the workflow. Node has no one formatter, linter or test runner, and a script is what `make lint` and `make test` call locally, so CI and a laptop run the same command at the versions `package-lock.json` records. A missing script fails the job before anything runs, naming it and the input that switches it off. `typecheck`, `lint` and `format` run after the suite, pass or fail, so one push reports every finding. <!-- docs-check: ignore -->
- **Installs are locked and verified.** `npm ci` fails when `package.json` and `package-lock.json` disagree (the counterpart of `python.yml`'s `locked` and `go.yml`'s `tidy`), and the job fails without a committed `package-lock.json`. `npm audit signatures` then checks every installed package against the registry's signatures. npm only: pnpm and Yarn lockfiles are not read.
- **`ignore-scripts` (default on) installs with `--ignore-scripts`**, so no dependency's install script runs in CI. Turn it off only for a dependency that builds a native module at install time.
- **Coverage is read from a Cobertura XML report.** With `coverage: true` the job runs `test:coverage` instead of `test`, which must write Cobertura to `coverage-file` (default `coverage/cobertura-coverage.xml`, where vitest and jest write it; vitest needs `cobertura` in `coverage.reporter`). The line total and a per-file table land in the job summary, and `coverage-pr-comment: true` posts them as one PR comment kept up to date across pushes. <!-- docs-check: ignore -->
- **`coverage-min` is a floor on total line coverage**, from the report's own counts, checked after a passing suite on every event, so `main` is held to it as well as pull requests.
- **`diff-coverage` gates the pull request's own lines**, exactly as in `python.yml` and `go.yml`: the same pinned `diff-cover` reads the report against `HEAD^1`, on `pull_request` after a passing suite. Its file paths are relative to the package directory, which diff-cover maps to the repository's.
- **Permissions:** `contents: read`, plus `pull-requests: write` for the comment. Without it the comment logs a warning and the suite still passes. The workflow declares no permissions of its own, so set them on the caller.

### Node inputs

| Input | Default | Description |
| --- | --- | --- |
| `working-directory` | `.` | Directory holding `package.json` and `package-lock.json` |
| `ignore-scripts` | `true` | Install with `npm ci --ignore-scripts` |
| `typecheck` | `true` | Run the `typecheck` script after the suite |
| `lint` | `true` | Run the `lint` script after the suite |
| `format` | `true` | Run the `format:check` script after the suite |
| `coverage` | `false` | Run `test:coverage` instead of `test`, reading its Cobertura report. Reported; gated only by the two inputs below |
| `coverage-file` | `coverage/cobertura-coverage.xml` | Where `test:coverage` writes the Cobertura report, relative to `working-directory` <!-- docs-check: ignore --> |
| `coverage-min` | `""` | Minimum total line coverage. Empty gates nothing. Needs `coverage` |
| `diff-coverage` | `""` | Minimum % of the PR's changed lines the suite must run. Empty gates nothing. Needs `coverage` |
| `coverage-pr-comment` | `false` | Post the coverage report as one self-updating PR comment. Needs `coverage` and `pull-requests: write` on the caller |
| `runs-on` | `ubuntu-latest` | Runner label |

## .NET CI

(v1.37.0+) Builds and tests a .NET solution on the SDK its `mise.toml` pins: a locked restore, `dotnet build` with warnings as errors, `dotnet test` on Microsoft.Testing.Platform, then `dotnet format`. Shaped like [Python CI](#python-ci), [Go CI](#go-ci) and [Node CI](#node-ci) on purpose, so a .NET repo carries the same required check and the same gates.

```yaml
name: ci-dotnet

on:
  pull_request:
    branches: [main]

permissions:
  contents: read
  pull-requests: write  # only needed for coverage-pr-comment

jobs:
  test:
    uses: jay-withers/workflows/.github/workflows/dotnet.yml@main
    with:
      coverage: true
      coverage-min: "90"
      diff-coverage: "90"
```

What the repository needs, all of it in [`tests/dotnet`](tests/dotnet):

- **`mise.toml` pins `dotnet`**, the SDK (`mise use dotnet@<version>`), 10 or later.
- **`global.json` opts `dotnet test` into Microsoft.Testing.Platform**: `{"test": {"runner": "Microsoft.Testing.Platform"}}`. Leave out an `sdk` block, or keep it equal to the mise pin.
- **`Directory.Build.props` sets `RestorePackagesWithLockFile`**, and each project's `packages.lock.json` is committed. Setting `EnforceCodeStyleInBuild` and an `AnalysisLevel` there too makes the build's warnings-as-errors the lint gate. Leave `TreatWarningsAsErrors` out and let the `warnings-as-errors` input decide: set in the props, it also fails restore on a new NuGet advisory, and the input can no longer turn the gate off.
- **Each test project references `Microsoft.Testing.Extensions.CodeCoverage`** when `coverage` is on.
- **Exclude `packages.lock.json` from the `pretty-format-json` and `end-of-file-fixer` hooks.** NuGet writes it with its own key order and no final newline, and rewrites it on every restore, so a hook that reformats it makes the lock check fail.

Notes:

- **The required status check is `<caller job id> / Test`**, the same as `python.yml`'s, `go.yml`'s and `node.yml`'s, so a repo moving from Python to .NET keeps `test / Test` and its branch protection needs no change.
- **The SDK comes from `mise.toml` and nowhere else.** There is no `dotnet-version` input and no `setup-dotnet` fallback. mise runs from `working-directory`, and the job fails naming the fix when no config from there up to the root pins `dotnet`. mise's SDK goes first on `PATH`, with `DOTNET_ROOT` pointing at it, ahead of the SDK the runner image has.
- **Tests run on Microsoft.Testing.Platform only.** It is what `dotnet test` runs from the .NET 10 SDK on, once `global.json` opts in, and what current xunit.v3, MSTest and TUnit releases are built for. On SDK 10+ they refuse the older VSTest mode. The job checks for the opt-in first, looking up from `working-directory` as the SDK does, and fails naming the fix.
- **`locked` (default on) restores with `--locked-mode`**, the counterpart of `python.yml`'s `locked` and `go.yml`'s `tidy`. NuGet fails when a lock file disagrees with the projects (NU1004), and the job also fails when the restore creates or changes a `packages.lock.json`, or when a tracked `.csproj`, `.fsproj` or `.vbproj` has no committed lock file beside it. The NuGet package cache is keyed on the SDK and every lock file.
- **`warnings-as-errors` (default on) builds with `-warnaserror`**, so compiler warnings, the analyzers and (with `EnforceCodeStyleInBuild`) code style all fail the job. That is the lint gate: there is no separate linter. NuGet's audit warnings (NU1900-NU1904) are excepted: see the audit note below.
- **`format` (default on) runs `dotnet format --verify-no-changes`** (whitespace, style and analyzer fixes) after the suite, pass or fail, so one push reports every finding.
- **`project`** names the `.sln`, `.slnx` or `.csproj` when `working-directory` holds more than one. It is passed to `dotnet test` as `--solution` or `--project`, since the MTP runner takes no positional path.
- **`coverage: true` measures line coverage** with Microsoft's collector, one Cobertura file per test project, and merges them with a pinned [ReportGenerator](https://reportgenerator.io/) run through `dotnet tool exec`, so nothing is installed. Its summary lands in the job summary, and `coverage-pr-comment: true` posts it as one PR comment kept up to date across pushes. A passing suite that writes no Cobertura file fails naming the missing package.
- **`coverage-min` is a floor on the merged total line coverage**, checked after a passing suite on every event, so `main` is held to it as well as pull requests. It needs `coverage: true`.
- **`diff-coverage` gates the pull request's own lines**, exactly as in `python.yml`: the same pinned `diff-cover`, against `HEAD^1`, on `pull_request` after a passing suite, reading the merged Cobertura file. It needs `coverage: true`. Both tool pins are kept current by regex managers in [`renovate.json`](renovate.json).
- **NuGet's vulnerability audit is not a gate here.** Restore reports advisories as warnings, which the build replays and `-warnnotaserror` keeps as warnings, and a published image is scanned by `docker.yml`'s Trivy gate, which fails a pull request only on a finding with a fix. Failing every PR on a new advisory in any transitive package would block work the PR didn't cause.
- **Permissions:** `contents: read`, plus `pull-requests: write` for the comment. Without it the comment logs a warning and the suite still passes. The workflow declares no permissions of its own, so set them on the caller.

### .NET inputs

| Input | Default | Description |
| --- | --- | --- |
| `working-directory` | `.` | Directory holding the solution or project, with `global.json` at or above it |
| `project` | `""` | The `.sln`, `.slnx` or `.csproj` to build and test, relative to `working-directory`. Empty lets the SDK find the one there |
| `configuration` | `Release` | Build configuration |
| `locked` | `true` | Restore with `--locked-mode`, and fail unless every `packages.lock.json` is committed and unchanged |
| `warnings-as-errors` | `true` | Build with `-warnaserror` |
| `format` | `true` | Fail if `dotnet format` would change any file |
| `coverage` | `false` | Measure line coverage. Reported; gated only by the two inputs below. Needs `Microsoft.Testing.Extensions.CodeCoverage` in each test project |
| `coverage-min` | `""` | Minimum total line coverage. Empty gates nothing. Needs `coverage` |
| `diff-coverage` | `""` | Minimum % of the PR's changed lines the suite must run. Empty gates nothing. Needs `coverage` |
| `coverage-pr-comment` | `false` | Post the coverage report as one self-updating PR comment. Needs `coverage` and `pull-requests: write` on the caller |
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
- **`"python"` on an image checks its interpreter against `mise.toml` (v1.35.0+).** Set it to the command that starts the image's Python (`{"name": "api", "context": ".", "python": "python"}`; `"python3"` for an image whose Python is the distribution's). On a build that does not push, every pull request and the daily build of `main`, the job runs that command in the built image and fails unless its major.minor matches the `python` pin in the repository root's `mise.toml`, which a local test run and `python.yml`'s suite run on. The two are pinned in different places (the base image is often another repository's), and nothing else compares them, so a green suite could otherwise say nothing about the interpreter that ships. It reads `[tools].python` from `mise.toml` or `.mise.toml`, as a string, a list (the first) or a table's `version`. Patch versions may differ. It runs after the Trivy scan and upload, so a mismatch never hides findings, and a multi-platform build (never loaded) skips it with a warning. Add `mise.toml` to the caller's image path filter, so a Python bump there runs the check too.
- **`"node"` on an image does the same for Node (v1.36.0+).** Set it to the command that starts the image's Node (`{"name": "web", "context": ".", "node": "node"}`). The job fails unless the image's Node major matches the `node` pin mise would use in the image's build context: the nearest `mise.toml` or `.mise.toml` from `context` up to the root that pins `node`, which is what a local run and `node.yml`'s suite (with `working-directory` set to the context) run on. Major only, since Node's release lines are its majors. The pin must be a number (`"26"`, `"26.13.1"`): an alias such as `"lts"` names no one version, so it fails the check. Like the Python check, it runs on builds that do not push, after the scan, and a multi-platform build skips it with a warning.
- **`"dotnet"` on an image does the same for .NET (v1.38.0+).** Set it to the command that starts the image's .NET host (`{"name": "api", "context": ".", "dotnet": "dotnet"}`). The job runs `dotnet --list-runtimes` in the image and fails unless every `Microsoft.NETCore.App` runtime there has the major.minor of the `dotnet` SDK pin in the nearest mise config from `context` up to the root, which `dotnet.yml`'s suite runs on (SDK `11.0.100` is runtime `11.0`). A framework-dependent app does not roll forward to a new runtime major by default, so without it a base image that moved runtime would pass the build and fail at startup. The pin must be a version (`"11"` reads as `11.0`). The SDK pin stands for the app's `TargetFramework`, so an image whose runtime is older than the SDK (an SDK 11 repo shipping a `net10.0` app) fails by design: pin the SDK the app targets. Add `mise.toml` to the caller's image path filter, so an SDK bump there runs the check too. Like the Python check, it runs on builds that do not push, after the scan, and a multi-platform build skips it with a warning.

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

**Build main daily, so a new CVE reaches you before it reaches a PR (v1.25.0+).** The gate only runs when something builds, and nothing builds main between merges. So a fix published for something in the image fails the next PR's `container-build`, whatever that PR is about, and every Renovate PR after it, until someone notices (security-testing's pyasn1 held five PRs for 13 days in November 2026). Run the PR workflow on a schedule as well, with `failure-issue` on outside pull requests: a failed build opens a `build-failed` issue that @-mentions the owner, a repeat failure comments on it, and the next success closes it. The caller grants `issues: write`; without it the report warns and the build's result stands. repo-agent's digest lists open `build-failed` issues.

```yaml
on:
  pull_request:
    branches: [main]
  schedule:
    - cron: "17 5 * * *"
  workflow_dispatch:

jobs:
  build:
    permissions:
      contents: read
      security-events: write
      issues: write # failure-issue
    uses: jay-withers/workflows/.github/workflows/docker.yml@main
    with:
      images: '[{"name": "api", "context": "."}]'
      failure-issue: ${{ github.event_name != 'pull_request' }}
```

### Docker inputs

| Input | Default | Description |
| --- | --- | --- |
| `images` | *required* | JSON array of `{"name", "context"}` objects. `name` is the last segment of the reference and the cache scope; `context` is the build context. One matrix leg each. (v1.35.0+) An optional `"python"` names the command that runs the image's interpreter, checked against `mise.toml`'s pin. (v1.36.0+) An optional `"node"` does the same for Node's major version. (v1.38.0+) An optional `"dotnet"` checks every .NET runtime in the image against the `dotnet` SDK pin's major.minor |
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
| `failure-issue` | `false` | Outside a pull request, open a `build-failed` issue when the build or the Trivy gate fails, and close it on the next success. Needs `issues: write` (v1.25.0+) |
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
- **Every language is analysed with `build-mode: none`**, so nothing is built: `python`, `actions`, `javascript-typescript` and `ruby` never need a build, and `csharp` (a .NET repo: `languages: '["csharp", "actions"]'`) and `java-kotlin` support analysing without one, reading the source and its project files. A language that can't (`c-cpp`, `go`, `swift`) would need a `build-mode` input.

### CodeQL inputs

| Input | Default | Description |
| --- | --- | --- |
| `languages` | `'["python", "actions"]'` | JSON array of CodeQL languages, one job each |
| `queries` | `security-extended` | Query suite: `security-extended` or `security-and-quality` |
| `runs-on` | `ubuntu-latest` | Runner label |

## Repo CI

This repo dogfoods its own reusable workflows by calling them with local paths (no `@ref` needed). These callers are prefixed `_self_` to distinguish them from the public reusable workflows — they are internal and not meant to be consumed by other repos:

- [`_self_ci.yml`](.github/workflows/_self_ci.yml) calls [`pre-commit.yml`](.github/workflows/pre-commit.yml) on every push and pull request — the hooks in [`.pre-commit-config.yaml`](.pre-commit-config.yaml) cover actionlint, gitleaks secret scanning and file hygiene. It also calls [`go.yml`](.github/workflows/go.yml) against the sample module in [`tests/go`](tests/go) with every gate but the PR comment on (format, lint, and both coverage floors at 90%), so a change to `go.yml` runs before any caller's pin moves. That job is not a required check. The diff-coverage gate only meets real lines on a PR that changes `tests/go/calc`, so touch it when changing how coverage is converted. A `node` job does the same for [`node.yml`](.github/workflows/node.yml) against the sample package in [`tests/node`](tests/node), whose diff-coverage meets real lines on a PR that changes `tests/node/src`. A `dotnet` job does the same for [`dotnet.yml`](.github/workflows/dotnet.yml) against the sample solution in [`tests/dotnet`](tests/dotnet) (touch `tests/dotnet/src/Calc` when changing how coverage is merged or diffed).
- [`_self_codeql.yml`](.github/workflows/_self_codeql.yml) calls [`codeql.yml`](.github/workflows/codeql.yml) with `languages: '["actions"]'`, scanning this repo's own workflow files, which are the only code here.
- [`_self_cd.yml`](.github/workflows/_self_cd.yml) calls [`release.yml`](.github/workflows/release.yml) on pushes to `main` with `update-major-tag: true`, so callers can pin to `@v1`.
- Every external action is pinned to a full commit SHA with the version in a trailing comment. A pre-commit hook (`pin-github-actions`) enforces this in CI, and Renovate keeps the pins up to date.
- Dependency updates come from the shared presets in [`renovate`](https://github.com/jay-withers/renovate); [`renovate.json`](renovate.json) just extends them, so policy changes land centrally.

## Development

Tools are pinned in [`mise.toml`](mise.toml): set up a machine once with [jay-withers/toolchain](https://github.com/jay-withers/toolchain), then `mise trust && make install` here (it runs `mise install` first, then sets up the git hooks). This repo's own CI installs from the same file. Useful targets:

```sh
make install     # install mise tools (mise.toml) and the pre-commit git hook
make lint        # actionlint (falls back to docker if not installed)
make pre-commit  # run all pre-commit hooks against the full repo
```

The same hooks run in CI via the repo's own [pre-commit workflow](.github/workflows/pre-commit.yml).

## Versioning

Callers pin a full commit SHA with the tag as a trailing comment (`@<sha> # v1.22.0`), and Renovate bumps the pin, so a change here rolls out repo by repo as each pin moves. `@v1` and `@main` work but are not used in this estate.
