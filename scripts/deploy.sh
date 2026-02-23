#!/usr/bin/env bash
# =============================================================================
# AWS Landing Zone - Deployment Script
# =============================================================================
# Deploys CloudFormation stacks in the correct dependency order:
#   1. VPC & Networking (Transit Gateway)
#   2. IAM & SSO (Identity Center)
#   3. Security Baseline (GuardDuty, SecurityHub, Config)
#
# Prerequisites:
#   - AWS CLI v2 configured with credentials for the target account
#   - IAM Identity Center enabled in the management account
#   - jq installed (brew install jq / apt install jq)
#
# Usage:
#   chmod +x scripts/deploy.sh
#   ./scripts/deploy.sh [deploy|destroy] [--region us-east-1] [--env landing-zone]
# =============================================================================

set -euo pipefail

# ─── DEFAULTS ─────────────────────────────────────────────────────────────────
ACTION="${1:-deploy}"
AWS_REGION="${AWS_REGION:-us-east-1}"
ENV_NAME="${ENV_NAME:-landing-zone}"
TEMPLATES_DIR="$(dirname "$0")/../templates"
PARAMS_DIR="$(dirname "$0")/../parameters"

# ─── COLORS ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ─── HELPERS ──────────────────────────────────────────────────────────────────
log_info()    { echo -e "${CYAN}[INFO]${NC}  $1"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }

check_prerequisites() {
  log_info "Checking prerequisites..."

  if ! command -v aws &>/dev/null; then
    log_error "AWS CLI not found. Install from https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html"
    exit 1
  fi

  AWS_CLI_VERSION=$(aws --version 2>&1 | cut -d/ -f2 | cut -d. -f1)
  if [[ "$AWS_CLI_VERSION" -lt 2 ]]; then
    log_error "AWS CLI v2 is required. Found: $(aws --version)"
    exit 1
  fi

  if ! command -v jq &>/dev/null; then
    log_error "jq not found. Install with: brew install jq (macOS) or apt install jq (Linux)"
    exit 1
  fi

  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || {
    log_error "Could not authenticate with AWS. Check your credentials."
    exit 1
  }
  log_success "Authenticated as account: ${ACCOUNT_ID} in region: ${AWS_REGION}"
}

# Deploy or update a CloudFormation stack
deploy_stack() {
  local stack_name="$1"
  local template_file="$2"
  local params_file="$3"

  log_info "Deploying stack: ${stack_name}..."

  # Validate template before deploying
  aws cloudformation validate-template \
    --template-body "file://${template_file}" \
    --region "${AWS_REGION}" > /dev/null

  log_success "Template ${template_file} validated."

  aws cloudformation deploy \
    --stack-name "${stack_name}" \
    --template-file "${template_file}" \
    --parameter-overrides "file://${params_file}" \
    --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
    --region "${AWS_REGION}" \
    --tags \
        Environment="${ENV_NAME}" \
        ManagedBy="CloudFormation" \
        DeployedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --no-fail-on-empty-changeset

  log_success "Stack ${stack_name} deployed successfully."

  # Print outputs
  log_info "Outputs for ${stack_name}:"
  aws cloudformation describe-stacks \
    --stack-name "${stack_name}" \
    --region "${AWS_REGION}" \
    --query "Stacks[0].Outputs" \
    --output table
}

# Destroy stacks in reverse order
destroy_stack() {
  local stack_name="$1"

  log_warn "Deleting stack: ${stack_name}..."
  aws cloudformation delete-stack \
    --stack-name "${stack_name}" \
    --region "${AWS_REGION}"

  aws cloudformation wait stack-delete-complete \
    --stack-name "${stack_name}" \
    --region "${AWS_REGION}"

  log_success "Stack ${stack_name} deleted."
}

# ─── MAIN ─────────────────────────────────────────────────────────────────────
main() {
  echo ""
  echo "========================================================"
  echo "  AWS Landing Zone Deployment"
  echo "  Action : ${ACTION}"
  echo "  Region : ${AWS_REGION}"
  echo "  Env    : ${ENV_NAME}"
  echo "========================================================"
  echo ""

  check_prerequisites

  STACK_VPC="${ENV_NAME}-vpc-networking"
  STACK_SSO="${ENV_NAME}-iam-sso"
  STACK_SEC="${ENV_NAME}-security-baseline"

  if [[ "${ACTION}" == "deploy" ]]; then
    # Deploy in dependency order
    deploy_stack "${STACK_VPC}" \
      "${TEMPLATES_DIR}/vpc-networking.yaml" \
      "${PARAMS_DIR}/vpc-networking.json"

    deploy_stack "${STACK_SSO}" \
      "${TEMPLATES_DIR}/iam-sso.yaml" \
      "${PARAMS_DIR}/iam-sso.json"

    deploy_stack "${STACK_SEC}" \
      "${TEMPLATES_DIR}/security-baseline.yaml" \
      "${PARAMS_DIR}/security-baseline.json"

    echo ""
    log_success "All stacks deployed successfully!"
    echo ""
    log_info "Next steps:"
    echo "  1. Share the Transit Gateway with spoke accounts via AWS RAM."
    echo "  2. Update SSM parameters with actual Identity Store Group IDs."
    echo "  3. Subscribe your security team's email to the SNS alerts topic."
    echo "  4. Run 'aws securityhub get-findings' to verify Security Hub is ingesting findings."

  elif [[ "${ACTION}" == "destroy" ]]; then
    log_warn "This will DELETE all landing zone stacks. This cannot be undone."
    read -rp "Type 'yes' to confirm: " CONFIRM
    if [[ "${CONFIRM}" != "yes" ]]; then
      log_info "Aborted."
      exit 0
    fi

    # Destroy in reverse dependency order
    destroy_stack "${STACK_SEC}"
    destroy_stack "${STACK_SSO}"
    destroy_stack "${STACK_VPC}"

    log_success "All stacks destroyed."

  else
    log_error "Unknown action: ${ACTION}. Use 'deploy' or 'destroy'."
    exit 1
  fi
}

main "$@"
