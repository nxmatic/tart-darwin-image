#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(realpath "$(dirname "${BASH_SOURCE[0]}")")"
ENV_FILE="${SCRIPT_DIR}/.envrc"
if [[ ! -f "${ENV_FILE}" && -n "${MACOS_ENV_FILE:-}" ]]; then
  ENV_FILE="${MACOS_ENV_FILE}"
fi
if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

: "${MACOS_DEBUG_MODE:=1}"
if [[ "${MACOS_DEBUG_MODE}" == "1" ]]; then
  set -x
fi

: "${PRIMARY_ACCOUNT_NAME:=nxmatic}"
: "${SECONDARY_ADMIN_NAME:=super}"
: "${AUTO_LOGIN_USER:=${PRIMARY_ACCOUNT_NAME}}"

resolve_existing_user() {
  local candidate
  for candidate in "$@"; do
    [[ -z "${candidate}" ]] && continue
    if dscl . -read "/Users/${candidate}" >/dev/null 2>&1; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  return 1
}

TARGET_USER="$(resolve_existing_user "${AUTO_LOGIN_USER}" "${PRIMARY_ACCOUNT_NAME}" "${SECONDARY_ADMIN_NAME}" "${SUDO_USER:-}" "${USER:-}" admin || true)"
if [[ -z "${TARGET_USER}" ]]; then
  echo "Warning: unable to resolve target user for screen sharing ACL; using '${PRIMARY_ACCOUNT_NAME}' best-effort." >&2
  TARGET_USER="${PRIMARY_ACCOUNT_NAME}"
fi

echo "Ensuring Remote Login and Screen Sharing are enabled (target user: ${TARGET_USER})."

# SSH access path (Screen Sharing diagnostics often pair with SSH fallback)
sudo systemsetup -setremotelogin on >/dev/null 2>&1 || true

# Native macOS Screen Sharing service
sudo launchctl enable system/com.apple.screensharing >/dev/null 2>&1 || true
sudo launchctl kickstart -k system/com.apple.screensharing >/dev/null 2>&1 || true

# ARD/VNC permissions path (idempotent best-effort)
KICKSTART_BIN="/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart"
if [[ -x "${KICKSTART_BIN}" ]]; then
  sudo "${KICKSTART_BIN}" -activate -configure -access -on -users "${TARGET_USER}" -privs -all -restart -agent >/dev/null 2>&1 || true
fi

echo "Screen Sharing enforcement completed."
