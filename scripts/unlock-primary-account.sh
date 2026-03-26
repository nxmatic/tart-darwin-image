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
: "${LOGINWINDOW_SHOW_FULLNAME:=0}"

if ! dscl . -read "/Users/${PRIMARY_ACCOUNT_NAME}" >/dev/null 2>&1; then
  echo "Primary account '${PRIMARY_ACCOUNT_NAME}' not found; skipping unlock/reset."
  exit 0
fi

sudo -n pwpolicy -u "${PRIMARY_ACCOUNT_NAME}" -setpolicy "isDisabled=0 maxFailedLoginAttempts=0 minutesUntilFailedLoginReset=0" >/dev/null 2>&1 || true
sudo -n dscl . -create "/Users/${PRIMARY_ACCOUNT_NAME}" failedLoginCount 0 >/dev/null 2>&1 || true

sudo -n pwpolicy -u "${PRIMARY_ACCOUNT_NAME}" -authentication-allowed 2>&1 || true

# Keep loginwindow in account tile/list mode by default.
# Set LOGINWINDOW_SHOW_FULLNAME=1 to force username/password input mode.
if [[ "${LOGINWINDOW_SHOW_FULLNAME}" == "1" ]]; then
  sudo -n defaults write /Library/Preferences/com.apple.loginwindow SHOWFULLNAME -bool true >/dev/null 2>&1 || true
else
  sudo -n defaults write /Library/Preferences/com.apple.loginwindow SHOWFULLNAME -bool false >/dev/null 2>&1 || true
fi
sudo -n defaults write /Library/Preferences/com.apple.loginwindow Hide500Users -bool false >/dev/null 2>&1 || true
sudo -n defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser "${PRIMARY_ACCOUNT_NAME}" >/dev/null 2>&1 || true

echo "Primary account unlock/reset ensured for ${PRIMARY_ACCOUNT_NAME}."