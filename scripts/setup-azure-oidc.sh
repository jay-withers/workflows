#!/usr/bin/env bash
# Sets up Azure OIDC federation for a GitHub repository:
#   1. Creates an app registration + service principal (idempotent)
#   2. Adds federated credentials for the repo (main branch, PRs, optional environment)
#   3. Assigns a role on the subscription
#   4. Sets AZURE_CLIENT_ID / AZURE_TENANT_ID / AZURE_SUBSCRIPTION_ID as GitHub Actions variables
#
# Requires: az (logged in), gh (authenticated), jq

set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") -r <owner/repo> [options]

Options:
  -r <owner/repo>     GitHub repository (required), e.g. jay-withers/my-infra
  -n <app-name>       App registration name (default: github-<owner>-<repo>)
  -s <subscription>   Azure subscription ID or name (default: current az subscription)
  -o <role>           Role to assign on the subscription (default: Contributor)
  -e <environment>    GitHub environment to federate (repeatable), e.g. -e production
  -b <branch>         Branch to federate (default: main)
  -h                  Show this help
EOF
  exit 1
}

REPO=""
APP_NAME=""
SUBSCRIPTION=""
ROLE="Contributor"
BRANCH="main"
ENVIRONMENTS=()

while getopts "r:n:s:o:e:b:h" opt; do
  case "$opt" in
    r) REPO="$OPTARG" ;;
    n) APP_NAME="$OPTARG" ;;
    s) SUBSCRIPTION="$OPTARG" ;;
    o) ROLE="$OPTARG" ;;
    e) ENVIRONMENTS+=("$OPTARG") ;;
    b) BRANCH="$OPTARG" ;;
    *) usage ;;
  esac
done

[[ -n "$REPO" ]] || usage
[[ "$REPO" == */* ]] || { echo "ERROR: -r must be in owner/repo format" >&2; exit 1; }

for cmd in az gh jq; do
  command -v "$cmd" >/dev/null || { echo "ERROR: $cmd is required" >&2; exit 1; }
done

APP_NAME="${APP_NAME:-github-${REPO//\//-}}"

if [[ -n "$SUBSCRIPTION" ]]; then
  az account set --subscription "$SUBSCRIPTION"
fi
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)

echo "==> Repository:    $REPO"
echo "==> App name:      $APP_NAME"
echo "==> Subscription:  $SUBSCRIPTION_ID"
echo "==> Tenant:        $TENANT_ID"
echo "==> Role:          $ROLE"

# --- App registration + service principal (idempotent) ----------------------
APP_ID=$(az ad app list --display-name "$APP_NAME" --query "[0].appId" -o tsv)
if [[ -z "$APP_ID" ]]; then
  echo "==> Creating app registration '$APP_NAME'"
  APP_ID=$(az ad app create --display-name "$APP_NAME" --query appId -o tsv)
else
  echo "==> App registration '$APP_NAME' already exists ($APP_ID)"
fi

if ! az ad sp show --id "$APP_ID" >/dev/null 2>&1; then
  echo "==> Creating service principal"
  az ad sp create --id "$APP_ID" >/dev/null
fi

# --- Federated credentials ---------------------------------------------------
add_federated_credential() {
  local name="$1" subject="$2"
  if az ad app federated-credential list --id "$APP_ID" --query "[?name=='$name']" -o tsv | grep -q .; then
    echo "==> Federated credential '$name' already exists"
    return
  fi
  echo "==> Adding federated credential '$name' ($subject)"
  az ad app federated-credential create --id "$APP_ID" --parameters "$(jq -n \
    --arg name "$name" --arg subject "$subject" \
    '{name: $name, issuer: "https://token.actions.githubusercontent.com", subject: $subject, audiences: ["api://AzureADTokenExchange"]}')" >/dev/null
}

add_federated_credential "branch-${BRANCH//\//-}" "repo:${REPO}:ref:refs/heads/${BRANCH}"
add_federated_credential "pull-request" "repo:${REPO}:pull_request"
for env in "${ENVIRONMENTS[@]}"; do
  add_federated_credential "environment-${env}" "repo:${REPO}:environment:${env}"
done

# --- Role assignment ----------------------------------------------------------
echo "==> Assigning '$ROLE' on subscription $SUBSCRIPTION_ID"
az role assignment create \
  --assignee "$APP_ID" \
  --role "$ROLE" \
  --scope "/subscriptions/${SUBSCRIPTION_ID}" \
  --only-show-errors >/dev/null || echo "==> Role assignment already exists"

# --- GitHub Actions variables --------------------------------------------------
echo "==> Setting GitHub Actions variables on $REPO"
gh variable set AZURE_CLIENT_ID --repo "$REPO" --body "$APP_ID"
gh variable set AZURE_TENANT_ID --repo "$REPO" --body "$TENANT_ID"
gh variable set AZURE_SUBSCRIPTION_ID --repo "$REPO" --body "$SUBSCRIPTION_ID"

cat <<EOF

Done. Use in the caller workflow:

  with:
    azure-client-id: \${{ vars.AZURE_CLIENT_ID }}
    azure-tenant-id: \${{ vars.AZURE_TENANT_ID }}
    azure-subscription-id: \${{ vars.AZURE_SUBSCRIPTION_ID }}
EOF
