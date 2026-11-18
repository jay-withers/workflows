#!/usr/bin/env bash
# Proves an image tag is live: `make smoke` after `make deploy`, locally or in
# container-apps-deploy.yml, which rolls back when this fails.
#
#   smoke.sh <tag> <resource-group> <image-without-tag> app:<name>... job:<name>...
#
# The one copy. Each app repo's `make smoke` fetches it from this repository at
# the commit its cd-publish pins container-apps-deploy.yml to, so CI and a
# local run use the same version, and Renovate's bump of that pin moves both.
# It used to be copied verbatim into every app repo.
#
# A green `az containerapp update` only means Azure accepted the image. The
# apps scale to zero, so a revision whose container never starts can go live
# unnoticed until someone opens the page. So for each app this checks, on its
# default FQDN (the custom domain may not be bound yet):
#
#   - the latest revision is configured with the image;
#   - /healthz answers 200 and reports the tag as `version`, retrying through
#     a cold start. An image from before `version` existed is accepted once the
#     latest *ready* revision is the one running it, so rolling back to one
#     still passes;
#   - /readyz answers 200 (not checked on a rollback to an image without
#     `version`, which may predate it).
#
# For a job, the configured image, and then one run of it with its args
# swapped for `selfcheck`: the same image, identity, env and secrets as a real
# run, but the app's selfcheck command only loads its settings, reads its
# secrets and reaches its storage or database, and sends nothing. A real run
# would email, spend LLM tokens or trade. Every job's run is started before
# any is waited on. With SMOKE_PHASE=rollback (container-apps-deploy.yml sets
# it) the runs are skipped: the old image may predate `selfcheck`, it has
# already run here, and restoring service shouldn't wait on it.
#
# With SMOKE_BROWSER=1 (container-apps-deploy.yml's `browser-check: true`),
# each app's home page is also loaded in Chromium on its default FQDN, once
# /readyz passes, and must end on a 200 with no console error. Unauthenticated:
# for a passcode-gated app that is the login page under the real deployed
# headers, so a broken base template, a missing asset or a CSP block fails the
# release. Needs uv, and Chromium's system libraries already installed
# (container-apps-deploy.yml installs both before deploying; on a laptop,
# `uvx --from playwright playwright install-deps chromium` once). Not on a
# rollback. A failed favicon load is ignored: several apps serve none.
set -euo pipefail

if [[ $# -lt 4 ]]; then
  echo "usage: $0 <tag> <resource-group> <image-without-tag> app:<name>|job:<name>..." >&2
  exit 2
fi
tag="$1" rg="$2" image="$3:$1"
shift 3
timeout="${SMOKE_TIMEOUT:-300}"
job_timeout="${SMOKE_JOB_TIMEOUT:-600}"
phase="${SMOKE_PHASE:-release}"
browser="${SMOKE_BROWSER:-0}"
# Pinned rather than floating, so the check can't change under a deploy.
# container-apps-deploy.yml passes its own pin, which it also installed.
playwright_version="${SMOKE_PLAYWRIGHT_VERSION:-1.65.2}"
browser_installed=0
body_file="$(mktemp)"
trap 'rm -f "$body_file"' EXIT
started=()

fail() {
  echo "smoke: FAIL: $*" >&2
  exit 1
}

# ARM answers the odd read with a 503 (market-agent's v0.26.3 deploy was
# rolled back for one), so read-only az calls get four tries. The POST that
# starts a selfcheck run doesn't: a retry could start a second run.
az_read() {
  local attempt
  for attempt in 1 2 3 4; do
    if az "$@"; then return 0; fi
    ((attempt < 4)) || return 1
    echo "smoke: az $1 $2 failed (try $attempt of 4), retrying in $((attempt * 10))s" >&2
    sleep $((attempt * 10))
  done
}

check_app() {
  local name="$1" app fqdn latest ready configured deadline body code version
  app="$(az_read containerapp show -g "$rg" -n "$name" -o json)"
  configured="$(jq -r '.properties.template.containers[0].image' <<<"$app")"
  [[ "$configured" == "$image" ]] || fail "$name is configured with $configured, not $image"
  fqdn="$(jq -r '.properties.configuration.ingress.fqdn // empty' <<<"$app")"
  [[ -n "$fqdn" ]] || fail "$name has no ingress FQDN"
  latest="$(jq -r '.properties.latestRevisionName' <<<"$app")"

  deadline=$((SECONDS + timeout))
  while :; do
    version=""
    code="$(curl -sS -o "$body_file" -w '%{http_code}' --max-time 30 "https://$fqdn/healthz" || true)"
    body="$(cat "$body_file" 2>/dev/null || true)"
    if [[ "$code" == 200 ]]; then
      version="$(jq -r '.version // empty' <<<"$body" 2>/dev/null || true)"
      if [[ "$version" == "$tag" ]]; then
        break
      elif [[ -z "$version" ]]; then
        ready="$(az_read containerapp show -g "$rg" -n "$name" --query properties.latestReadyRevisionName -o tsv)"
        [[ "$ready" == "$latest" ]] && break
      fi
    fi
    ((SECONDS < deadline)) || fail "$name: /healthz never reported $tag within ${timeout}s (last: HTTP $code ${body:0:200})"
    echo "smoke: $name: waiting (HTTP $code${version:+, version $version})"
    sleep 10
  done

  # Rolling back to an image from before `version`: it may predate /readyz too
  # (market-agent's dashboard did), and it has already run here.
  if [[ "$phase" == rollback && -z "$version" ]]; then
    echo "smoke: $name: $tag live (rollback to an image without version; /readyz not checked)"
    return 0
  fi

  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 "https://$fqdn/readyz" || true)"
  [[ "$code" == 200 ]] || fail "$name: /readyz answered HTTP $code"
  echo "smoke: $name: $tag live and ready on https://$fqdn"

  if [[ "$browser" == 1 && "$phase" != rollback ]]; then
    check_browser "$name" "https://$fqdn/"
  fi
}

check_browser() {
  local name="$1" url="$2"
  command -v uv >/dev/null || fail "SMOKE_BROWSER=1 needs uv on PATH (the repo's mise.toml)"
  if ((browser_installed == 0)); then
    # A no-op when the workflow already installed this version's Chromium.
    # Never --with-deps here: that is apt under sudo, inside a smoke test
    # whose failure rolls a release back.
    uv run --quiet --no-project --with "playwright==$playwright_version" \
      playwright install chromium >/dev/null ||
      fail "could not install Chromium for the browser check"
    browser_installed=1
  fi
  uv run --quiet --no-project --with "playwright==$playwright_version" \
    python - "$url" <<'PY' || fail "$name: the browser check of $url failed"
import sys

from playwright.sync_api import sync_playwright

url = sys.argv[1]
errors = []
with sync_playwright() as p:
    browser = p.chromium.launch()
    page = browser.new_page()
    page.on(
        "console",
        lambda m: errors.append(m.text)
        if m.type == "error" and not m.location.get("url", "").endswith("/favicon.ico")
        else None,
    )
    page.on("pageerror", lambda e: errors.append(str(e)))
    response = page.goto(url, wait_until="load", timeout=60_000)
    page.wait_for_timeout(1_000)  # a console error raised just after load
    status, landed = (response.status if response else 0), page.url
    browser.close()

print(f"smoke: browser: {url} -> {landed} (HTTP {status})")
for error in errors:
    print(f"smoke: browser: console error: {error}", file=sys.stderr)
sys.exit(0 if status == 200 and not errors else 1)
PY
  echo "smoke: $name: renders in Chromium with no console error"
  [[ -z "${SMOKE_BROWSER_MARKER:-}" ]] || touch "$SMOKE_BROWSER_MARKER"
}

check_job() {
  local name="$1" job configured body execution
  job="$(az_read containerapp job show -g "$rg" -n "$name" -o json)"
  configured="$(jq -r '.properties.template.containers[0].image' <<<"$job")"
  [[ "$configured" == "$image" ]] || fail "job $name is configured with $configured, not $image"
  echo "smoke: job $name: configured with $tag"
  [[ "$phase" != rollback ]] || return 0

  # The job's own template, args swapped. ARM's start API rather than
  # `az containerapp job start --args`, which builds the override from its
  # flags alone and drops the env (and with it every secret reference).
  body="$(jq -c '.properties.template | {
      containers: [.containers[] | {image, name, command, env, resources} + {args: ["selfcheck"]}],
      initContainers: [(.initContainers // [])[] | {image, name, command, args, env, resources}]
    } | (.containers, .initContainers) |= map(with_entries(select(.value != null)))' <<<"$job")"
  execution="$(az rest --method post \
    --url "https://management.azure.com$(jq -r .id <<<"$job")/start?api-version=2024-03-01" \
    --body "$body" --query name -o tsv)"
  [[ -n "$execution" ]] || fail "job $name: could not start a selfcheck run"
  echo "smoke: job $name: selfcheck run $execution started"
  started+=("$name/$execution")
}

wait_for_runs() {
  local entry name execution status deadline=$((SECONDS + job_timeout))
  for entry in "${started[@]}"; do
    name="${entry%%/*}" execution="${entry#*/}"
    while :; do
      status="$(az_read containerapp job execution show -g "$rg" -n "$name" \
        --job-execution-name "$execution" --query properties.status -o tsv)"
      case "$status" in
        Succeeded) echo "smoke: job $name: selfcheck run succeeded"; break ;;
        Failed | Stopped | Degraded)
          fail "job $name: selfcheck run $execution ended $status. Logs: az containerapp job logs show -g $rg -n $name --execution $execution --container <name>" ;;
      esac
      ((SECONDS < deadline)) || fail "job $name: selfcheck run $execution still $status after ${job_timeout}s"
      sleep 10
    done
  done
}

for target in "$@"; do
  case "$target" in
    app:*) check_app "${target#app:}" ;;
    job:*) check_job "${target#job:}" ;;
    *) echo "smoke: unknown target $target (want app:<name> or job:<name>)" >&2; exit 2 ;;
  esac
done
((${#started[@]} == 0)) || wait_for_runs
