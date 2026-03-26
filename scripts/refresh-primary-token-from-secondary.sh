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
: "${PRIMARY_ACCOUNT_PASSWORD:=nxmatic}"
: "${SECONDARY_ADMIN_NAME:=super}"
: "${SECONDARY_ADMIN_PASSWORD:=super}"
: "${SYSTEM_ADMIN_NAME:=admin}"
: "${SYSTEM_ADMIN_PASSWORD:=admin}"
: "${MACOS_DEBUG_MODE:=1}"
: "${PRIMARY_SECURE_TOKEN_ENFORCE:=1}"

ensure_secondary_admin_prerequisites() {
  local ensure_script token_status

  ensure_script="${SCRIPT_DIR}/ensure-secondary-admin-user.sh"
  if [[ -x "${ensure_script}" ]]; then
    echo "Ensuring secondary admin prerequisites via ${ensure_script}."
    bash "${ensure_script}" || true
  else
    echo "Warning: secondary admin ensure script not found at ${ensure_script}; continuing with existing state." >&2
  fi

  if ! dscl . -read "/Users/${SECONDARY_ADMIN_NAME}" >/dev/null 2>&1; then
    echo "Warning: secondary admin user '${SECONDARY_ADMIN_NAME}' is missing before SecureToken reconciliation." >&2
    return 0
  fi

  token_status="$(sysadminctl -secureTokenStatus "${SECONDARY_ADMIN_NAME}" 2>&1 || true)"
  if grep -qi "ENABLED" <<<"${token_status}"; then
    echo "Secondary admin '${SECONDARY_ADMIN_NAME}' has SecureToken enabled."
  else
    echo "Warning: secondary admin '${SECONDARY_ADMIN_NAME}' SecureToken is not enabled prior to reconciliation." >&2
  fi
}

ensure_primary_secure_token_from_secondary() {
  local token_status secondary_token_status system_admin_token_status grant_output

  token_status="$(sysadminctl -secureTokenStatus "${PRIMARY_ACCOUNT_NAME}" 2>&1 || true)"
  if grep -qi "ENABLED" <<<"${token_status}"; then
    echo "SecureToken already enabled for ${PRIMARY_ACCOUNT_NAME}."
    return 0
  fi

  secondary_token_status="$(sysadminctl -secureTokenStatus "${SECONDARY_ADMIN_NAME}" 2>&1 || true)"
  if ! grep -qi "ENABLED" <<<"${secondary_token_status}"; then
    if [[ "${PRIMARY_SECURE_TOKEN_ENFORCE}" == "1" ]]; then
      echo "Error: secondary admin '${SECONDARY_ADMIN_NAME}' does not have SecureToken enabled; cannot grant SecureToken to '${PRIMARY_ACCOUNT_NAME}' non-interactively." >&2
      exit 1
    fi
    echo "Warning: secondary admin '${SECONDARY_ADMIN_NAME}' does not have SecureToken enabled; skipping SecureToken reconciliation for '${PRIMARY_ACCOUNT_NAME}'." >&2
    return 0
  fi

  if ! dscl . -read "/Users/${SYSTEM_ADMIN_NAME}" >/dev/null 2>&1; then
    if [[ "${PRIMARY_SECURE_TOKEN_ENFORCE}" == "1" ]]; then
      echo "Error: token-authority admin user '${SYSTEM_ADMIN_NAME}' is missing; cannot grant SecureToken to '${PRIMARY_ACCOUNT_NAME}'." >&2
      exit 1
    fi
    echo "Warning: token-authority admin user '${SYSTEM_ADMIN_NAME}' is missing; skipping SecureToken reconciliation for '${PRIMARY_ACCOUNT_NAME}'." >&2
    return 0
  fi

  system_admin_token_status="$(sysadminctl -secureTokenStatus "${SYSTEM_ADMIN_NAME}" 2>&1 || true)"
  if ! grep -qi "ENABLED" <<<"${system_admin_token_status}"; then
    if [[ "${PRIMARY_SECURE_TOKEN_ENFORCE}" == "1" ]]; then
      echo "Error: token-authority admin user '${SYSTEM_ADMIN_NAME}' does not have SecureToken enabled; cannot grant SecureToken to '${PRIMARY_ACCOUNT_NAME}'." >&2
      exit 1
    fi
    echo "Warning: token-authority admin user '${SYSTEM_ADMIN_NAME}' does not have SecureToken enabled; skipping SecureToken reconciliation for '${PRIMARY_ACCOUNT_NAME}'." >&2
    return 0
  fi

  echo "Ensuring SecureToken for ${PRIMARY_ACCOUNT_NAME} using ${SYSTEM_ADMIN_NAME}."
  grant_output="$(sysadminctl -adminUser "${SYSTEM_ADMIN_NAME}" -adminPassword "${SYSTEM_ADMIN_PASSWORD}" -secureTokenOn "${PRIMARY_ACCOUNT_NAME}" -password "${PRIMARY_ACCOUNT_PASSWORD}" 2>&1 || true)"
  if [[ -n "${grant_output}" ]] && ! grep -qi "ENABLED" <<<"${grant_output}"; then
    echo "SecureToken grant command output: ${grant_output}" >&2
  fi

  token_status="$(sysadminctl -secureTokenStatus "${PRIMARY_ACCOUNT_NAME}" 2>&1 || true)"
  if grep -qi "ENABLED" <<<"${token_status}"; then
    echo "SecureToken enabled for ${PRIMARY_ACCOUNT_NAME}."
  else
    if [[ "${PRIMARY_SECURE_TOKEN_ENFORCE}" == "1" ]]; then
      echo "Error: SecureToken is not enabled for '${PRIMARY_ACCOUNT_NAME}' after reconciliation." >&2
      exit 1
    fi
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
  sudo defaults write /Library/Preferences/com.apple.loginwindow SHOWFULLNAME -bool false || true
  sudo defaults write /Library/Preferences/com.apple.loginwindow Hide500Users -bool false || true
  echo "Final autoLoginUser policy applied: ${target_auto_login} (MACOS_DEBUG_MODE=${MACOS_DEBUG_MODE})"
}

ensure_secondary_admin_prerequisites
ensure_primary_secure_token_from_secondary
apply_final_auto_login_policy
