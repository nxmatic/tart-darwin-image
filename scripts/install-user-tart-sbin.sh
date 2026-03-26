#!/usr/bin/env bash
set -euo pipefail
set -x

SCRIPT_DIR="$(realpath "$(dirname "${BASH_SOURCE[0]}")")"
DSCL_HELPER_LIB="${SCRIPT_DIR}/lib/dscl-plist.sh"
if [[ -f "${DSCL_HELPER_LIB}" ]]; then
  # shellcheck disable=SC1091
  source "${DSCL_HELPER_LIB}"
fi
ENV_FILE="${SCRIPT_DIR}/.envrc"
if [[ ! -f "${ENV_FILE}" && -n "${MACOS_ENV_FILE:-}" ]]; then
  ENV_FILE="${MACOS_ENV_FILE}"
fi
if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

: "${PRIMARY_ACCOUNT_NAME:=admin}"
: "${TART_USER_SBIN_REL_PATH:=/opt/tart/sbin}"

if declare -F dscl_user_home_dir >/dev/null 2>&1; then
  PRIMARY_HOME="$(dscl_user_home_dir "${PRIMARY_ACCOUNT_NAME}")"
else
  PRIMARY_HOME="/Users/${PRIMARY_ACCOUNT_NAME}"
fi

if [[ "${PRIMARY_ACCOUNT_NAME}" != "admin" && "${PRIMARY_HOME}" == "/Users/admin" ]]; then
  echo "Warning: primary account home resolved to /Users/admin; using canonical /Users/${PRIMARY_ACCOUNT_NAME} for helper install target."
  PRIMARY_HOME="/Users/${PRIMARY_ACCOUNT_NAME}"
fi

if [[ "${TART_USER_SBIN_REL_PATH}" == /* ]]; then
  TARGET_DIR="${TART_USER_SBIN_REL_PATH}"
else
  TARGET_DIR="${PRIMARY_HOME}/${TART_USER_SBIN_REL_PATH}"
fi
sudo install -d -m 0755 "${TARGET_DIR}"

install_helper() {
  local src_name="$1"
  local dst_name="$2"

  if [[ ! -f "${SCRIPT_DIR}/${src_name}" ]]; then
    echo "Warning: source script missing: ${SCRIPT_DIR}/${src_name}" >&2
    return 0
  fi

  sudo install -m 0755 "${SCRIPT_DIR}/${src_name}" "${TARGET_DIR}/${dst_name}"
  sudo chown "${PRIMARY_ACCOUNT_NAME}:staff" "${TARGET_DIR}/${dst_name}" || true
}

install_helper "manage-cache-volumes.sh" "manage-cache-volumes"
install_helper "relax-user-permissions.sh" "relax-user-permissions"
install_helper "migrate-tart-home-to-opt.sh" "migrate-tart-home-to-opt"
install_helper "run-provision-sequence.sh" "run-provision-sequence"
install_helper "trim-vscode-vm-services.sh" "trim-vscode-vm-services"
install_helper "install-tart-guest-agent.sh" "install-tart-guest-agent"

echo "Installed helper scripts to ${TARGET_DIR} for ${PRIMARY_ACCOUNT_NAME}."