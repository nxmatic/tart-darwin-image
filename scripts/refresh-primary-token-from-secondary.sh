#!/usr/bin/env bash
set -euo pipefail
set -x

SCRIPT_DIR="$(realpath "$(dirname "${BASH_SOURCE[0]}")")"
ENV_FILE="${SCRIPT_DIR}/.envrc"
if [[ ! -f "${ENV_FILE}" && -n "${MACOS_ENV_FILE:-}" ]]; then
  ENV_FILE="${MACOS_ENV_FILE}"
fi
if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

: "${PRIMARY_ACCOUNT_NAME:=nxmatic}"
: "${PRIMARY_ACCOUNT_PASSWORD:=admin}"
: "${SECONDARY_ADMIN_NAME:=super}"
: "${SECONDARY_ADMIN_PASSWORD:=super}"
: "${MACOS_DEBUG_MODE:=1}"

ensure_primary_secure_token_from_secondary() {
  local token_status

  token_status="$(sysadminctl -secureTokenStatus "${PRIMARY_ACCOUNT_NAME}" 2>&1 || true)"
  if grep -qi "ENABLED" <<<"${token_status}"; then
    echo "SecureToken already enabled for ${PRIMARY_ACCOUNT_NAME}."
    return 0
  fi

  echo "Ensuring SecureToken for ${PRIMARY_ACCOUNT_NAME} using ${SECONDARY_ADMIN_NAME}."
  sysadminctl -adminUser "${SECONDARY_ADMIN_NAME}" -adminPassword "${SECONDARY_ADMIN_PASSWORD}" -secureTokenOn "${PRIMARY_ACCOUNT_NAME}" -password "${PRIMARY_ACCOUNT_PASSWORD}" >/dev/null 2>&1 || true

  token_status="$(sysadminctl -secureTokenStatus "${PRIMARY_ACCOUNT_NAME}" 2>&1 || true)"
  if grep -qi "ENABLED" <<<"${token_status}"; then
    echo "SecureToken enabled for ${PRIMARY_ACCOUNT_NAME}."
  else
    echo "Warning: unable to ensure SecureToken for ${PRIMARY_ACCOUNT_NAME} from ${SECONDARY_ADMIN_NAME}." >&2
  fi
}

apply_final_auto_login_policy() {
  local target_auto_login

  if [[ "${MACOS_DEBUG_MODE}" == "1" ]]; then
    target_auto_login="${SECONDARY_ADMIN_NAME}"
  else
    target_auto_login="${PRIMARY_ACCOUNT_NAME}"
  fi

  sudo defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser "${target_auto_login}"
  echo "Final autoLoginUser policy applied: ${target_auto_login} (MACOS_DEBUG_MODE=${MACOS_DEBUG_MODE})"
}

ensure_primary_secure_token_from_secondary
apply_final_auto_login_policy
