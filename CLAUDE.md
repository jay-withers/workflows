# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with
code in this repository.

## What this repo does

The reusable GitHub Actions workflows behind every `ci-*` and `cd-*` workflow
in every `jay-withers` repo. Callers are thin: they pick a workflow here, pass
inputs and grant permissions. How a job *works* (plan, apply, build, scan,
deploy, smoke test, roll back, tag) lives here, so a change made once reaches
every repo. Only what is specific to one repo (its `make deploy`, its
`scripts/smoke.sh`, which images it builds) stays in that repo.

[README.md](README.md) is the reference: one section per workflow, with a
caller example, every input, and the notes on what each one needs. The
estate-wide view of how these fit together (what deploys on merge, the
`terraform-pending` / `deploy-pending` / `deploy-failed` issues, identities)
is `docs/delivery.md` in `jay-withers/factory`.

## Layout

```text
.github/workflows/
  terraform.yml               credential-free init + validate (+ terraform test)
  terraform-deploy.yml        OIDC plan, optional apply, drift check, pending/failed issues
  terraform-unlock.yml        manual force-unlock of a stuck state lock
  container-apps-deploy.yml   gate, provenance check, make deploy, make smoke, rollback, Deployments_CL row
  docker.yml                  build, optional push, Trivy, provenance + SBOM attestations
  pre-commit.yml              pre-commit run --all-files (optional Terraform toolchain)
  python.yml                  uv + pytest, optional coverage and Postgres
  codeql.yml                  CodeQL per language
  release.yml                 semver tag + GitHub release from Conventional Commits
  _self_*.yml                 this repo's own callers (CI, CodeQL, release) - not for other repos
```

Each workflow opens with a long header comment explaining *why* it is built
the way it is. Read it before changing the workflow, and keep it current.

## How a change reaches callers

- **Callers pin a commit SHA with the tag as a comment**
  (`terraform-deploy.yml@e58b7ed… # v1.20.0`), and Renovate bumps the pin.
  Merging here changes nothing anywhere until a caller's pin moves, and pins
  differ between repos (`grep -rh 'jay-withers/workflows/' ../../repos/*/.github`
  from the factory shows them).
- **Merging to `main` cuts a release** (`_self_cd.yml` → `release.yml`):
  `feat:` → minor, `fix:` → patch, `!`/`BREAKING CHANGE` → major, and the `v1`
  tag moves to it. A breaking change needs a major and a PR to every caller,
  so avoid one.
- **Stay backward compatible.** New behaviour comes in as an input with a
  default that keeps today's behaviour, or as a step that warns and carries
  on when a caller hasn't granted the new permission yet. An existing caller
  must keep working on the new pin unchanged. Say in the PR what callers have
  to change to use the new feature.
- **When a feature needs a minimum version, say so** where it's documented,
  as "(v1.22.0+)" in the README and in factory's `docs/delivery.md`, and
  update delivery.md in a factory PR when the change alters the estate-wide
  flow.

## Rules that are easy to break

- **Check names are API.** A call reports as `<caller job id> / <job name>`
  (`pre-commit / Pre-commit`, `test / Test`, `terraform / Terraform`), and
  github-repos requires those exact names. Renaming a job's `name:` leaves
  every repo's required check pending for ever.
- **A required check must always report.** Never put a path filter on a
  trigger. Filter inside the workflow (a `changes` job), and have the gate job
  treat *skipped* as success.
- **Permissions come from the caller.** A called workflow can't hold more than
  its caller, so `python.yml`, `docker.yml` and `codeql.yml` declare no
  top-level `permissions`. Document every permission a workflow needs in the
  README's notes, and warn rather than fail when an optional one is missing.
- **Secrets need `secrets: inherit` on the calling job.** Without it the
  called job sees no secrets at all, its own environment's included. Read
  credentials from the job's GitHub environment, never repository secrets.
- **Never apply or deploy from a `pull_request`.** `terraform-deploy.yml` and
  `container-apps-deploy.yml` refuse it explicitly. Keep those guards.
- **Never cancel an apply or deploy in progress** (`cancel-in-progress:
  false`). A killed apply leaves state locked.
- **Pin every external action to a full SHA** with the version in a trailing
  comment. The `pin-github-actions` hook enforces it.
- **Untrusted input goes through `env:`**, never `${{ }}` inside `run:`.
  CodeQL scans this repo's workflows for exactly that, and high/critical
  alerts block merges.

## Verifying a change

There is no test suite. Before opening a PR:

- `make pre-commit` runs every hook, including actionlint, shellcheck on the
  inline scripts, and gitleaks. `make lint` runs actionlint alone.
- Run any non-trivial inline shell locally against stubbed inputs (a fake
  `gh` on `PATH`, a sample plan or lock file), one case per branch of the
  logic, and list the cases in the PR.
- For a behaviour change, say which caller should take the new pin first.
  A good pilot is gym-log, the reference app repo the others copy from.

## Commands

```bash
make install      # install pre-commit and the git hooks
make lint         # actionlint (falls back to docker if not installed)
make pre-commit   # run all pre-commit hooks against the full repo
```

## CI and commits

- Required check: `pre-commit / Pre-commit` (`_self_ci.yml`). CodeQL
  (`_self_codeql.yml`) also gates through code scanning.
- Commits follow [Conventional Commits](https://www.conventionalcommits.org/),
  enforced by commitlint. Scope by workflow where it helps:
  `feat(terraform-deploy): …`, `fix(container-apps-deploy): …`.
- Renovate extends the shared `jay-withers/renovate` presets.
