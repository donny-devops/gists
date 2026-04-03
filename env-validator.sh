#!/usr/bin/env bash
# =============================================================================
# env-validator.sh
# Validate that all required environment variables are set before app startup.
# Supports: required vars, optional vars with defaults, format validation (URL, int).
#
# Usage (source it at the top of your entrypoint script):
#   source ./env-validator.sh
#
# Or run standalone to check an .env file:
#   ./env-validator.sh .env
#
# Configuration:
#   Edit the REQUIRED_VARS and OPTIONAL_VARS arrays below for your app.
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration — edit these for your application
# -----------------------------------------------------------------------------

# Required: script exits with error if any of these are unset or empty
REQUIRED_VARS=(
  "DATABASE_URL"
  "SECRET_KEY"
  "APP_ENV"
)

# Optional with defaults: set these if not already defined
declare -A OPTIONAL_VARS=(
  ["PORT"]="8080"
  ["LOG_LEVEL"]="info"
  ["WORKERS"]="2"
  ["DEBUG"]="false"
)

# Format validations: variable name → pattern type
# Supported types: url, int, bool, nonempty
declare -A VAR_FORMATS=(
  ["DATABASE_URL"]="url"
  ["PORT"]="int"
  ["DEBUG"]="bool"
  ["LOG_LEVEL"]="nonempty"
)

# -----------------------------------------------------------------------------
# Implementation
# -----------------------------------------------------------------------------

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ERRORS=0
WARNINGS=0

log_ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
log_warn() { echo -e "  ${YELLOW}⚠${NC} $1"; ((WARNINGS++)) || true; }
log_err()  { echo -e "  ${RED}✗${NC} $1" >&2; ((ERRORS++)) || true; }

load_env_file() {
  local env_file="$1"
  if [[ ! -f "$env_file" ]]; then
    log_warn ".env file not found at '${env_file}' — skipping file load."
    return 0
  fi
  log_ok "Loading: ${env_file}"
  # Export variables from .env file (skip comments and empty lines)
  set -o allexport
  # shellcheck disable=SC1090
  source <(grep -v '^#' "$env_file" | grep -v '^[[:space:]]*$')
  set +o allexport
}

validate_format() {
  local name="$1"
  local value="$2"
  local fmt="${VAR_FORMATS[$name]:-}"

  [[ -z "$fmt" ]] && return 0

  case "$fmt" in
    url)
      if [[ ! "$value" =~ ^(https?|postgres|postgresql|redis|amqp)://. ]]; then
        log_err "${name}: '${value}' does not look like a valid URL."
      fi
      ;;
    int)
      if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        log_err "${name}: '${value}' is not an integer."
      fi
      ;;
    bool)
      if [[ ! "$value" =~ ^(true|false|1|0|yes|no)$ ]]; then
        log_err "${name}: '${value}' is not a boolean (true/false/1/0/yes/no)."
      fi
      ;;
    nonempty)
      [[ -z "$value" ]] && log_err "${name} must not be empty."
      ;;
  esac
}

validate_required() {
  echo -e "\n${GREEN}Required Variables:${NC}"
  for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
      log_err "${var} is NOT set (required)."
    else
      # Mask secrets in output
      local display
      if [[ "$var" =~ (SECRET|PASSWORD|KEY|TOKEN|PASS) ]]; then
        display="$(echo "${!var}" | head -c 4)****"
      else
        display="${!var}"
      fi
      validate_format "$var" "${!var}"
      [[ $ERRORS -eq 0 ]] && log_ok "${var}=${display}"
    fi
  done
}

apply_defaults() {
  echo -e "\n${GREEN}Optional Variables (with defaults):${NC}"
  for var in "${!OPTIONAL_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
      export "$var"="${OPTIONAL_VARS[$var]}"
      log_warn "${var} not set — using default: ${OPTIONAL_VARS[$var]}"
    else
      validate_format "$var" "${!var}"
      log_ok "${var}=${!var}"
    fi
  done
}

summary() {
  echo ""
  if [[ $ERRORS -gt 0 ]]; then
    echo -e "${RED}Validation FAILED: ${ERRORS} error(s), ${WARNINGS} warning(s).${NC}"
    echo -e "${RED}Fix the above errors before starting the application.${NC}"
    exit 1
  elif [[ $WARNINGS -gt 0 ]]; then
    echo -e "${YELLOW}Validation passed with ${WARNINGS} warning(s).${NC}"
  else
    echo -e "${GREEN}All environment variables validated successfully.${NC}"
  fi
}

main() {
  echo -e "${GREEN}=== Environment Validator ===${NC}"
  [[ -n "${1:-}" ]] && load_env_file "$1"
  validate_required
  apply_defaults
  summary
}

main "${1:-}"
