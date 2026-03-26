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

: "${PRIMARY_ACCOUNT_NAME:=nxmatic}"
: "${TART_HOME_TARGET:=/opt/tart}"
: "${TART_HOME_SOURCE:=}"
: "${TART_HOME_LINK:=1}"

if declare -F dscl_user_home_dir >/dev/null 2>&1; then
  PRIMARY_HOME="$(dscl_user_home_dir "${PRIMARY_ACCOUNT_NAME}")"
else
  PRIMARY_HOME="/Users/${PRIMARY_ACCOUNT_NAME}"
fi

if [[ -z "${TART_HOME_SOURCE}" ]]; then
  TART_HOME_SOURCE="${PRIMARY_HOME}/.tart"
fi

if [[ "${TART_HOME_SOURCE}" == "${TART_HOME_TARGET}" ]]; then
  echo "TART_HOME source and target are identical (${TART_HOME_SOURCE}); nothing to migrate."
  exit 0
fi

sudo install -d -m 0755 "${TART_HOME_TARGET}"
sudo install -d -m 0755 "${TART_HOME_TARGET}/sbin"

if [[ -L "${TART_HOME_SOURCE}" ]]; then
  echo "Source is already a symlink: ${TART_HOME_SOURCE}"
elif [[ -d "${TART_HOME_SOURCE}" ]]; then
  if command -v rsync >/dev/null 2>&1; then
    sudo rsync -aH --delete "${TART_HOME_SOURCE}/" "${TART_HOME_TARGET}/"
  else
    sudo ditto "${TART_HOME_SOURCE}" "${TART_HOME_TARGET}"
  fi

  backup_path="${TART_HOME_SOURCE}.backup.$(date -u +%Y%m%dT%H%M%SZ)"
  sudo mv "${TART_HOME_SOURCE}" "${backup_path}"
  echo "Backed up previous tart home to ${backup_path}"
else
  echo "Source tart home missing (${TART_HOME_SOURCE}); initializing target only."
fi

if [[ "${TART_HOME_LINK}" == "1" ]]; then
  sudo ln -sfn "${TART_HOME_TARGET}" "${TART_HOME_SOURCE}"
  sudo chown -h "${PRIMARY_ACCOUNT_NAME}:staff" "${TART_HOME_SOURCE}" || true
fi

sudo chown -R "${PRIMARY_ACCOUNT_NAME}:staff" "${TART_HOME_TARGET}" || true

echo "Tart home migration completed."
echo "  source: ${TART_HOME_SOURCE}"
echo "  target: ${TART_HOME_TARGET}"
echo "Use this in shell profile if desired: export TART_HOME=${TART_HOME_TARGET}"
