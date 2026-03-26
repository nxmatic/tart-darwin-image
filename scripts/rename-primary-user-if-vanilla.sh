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

: "${MACOS_BUILD_SOURCE_MODE:=clone}"
: "${PRIMARY_ACCOUNT_NAME:=admin}"
: "${PRIMARY_ACCOUNT_FULL_NAME:=Stephane Lacoin (aka nxmatic)}"
: "${PRIMARY_ACCOUNT_ALIAS:=nxmatic}"
: "${PRIMARY_ACCOUNT_EXPECTED_UID:=0}"
: "${AUTO_LOGIN_USER:=${PRIMARY_ACCOUNT_NAME}}"
: "${PRIMARY_ACCOUNT_PASSWORD:=nxmatic}"
: "${SECONDARY_ADMIN_NAME:=super}"
: "${SECONDARY_ADMIN_PASSWORD:=super}"
: "${SYSTEM_ADMIN_NAME:=admin}"
: "${SYSTEM_ADMIN_PASSWORD:=admin}"
: "${PRIMARY_SECURE_TOKEN_REFRESH:=1}"

resolve_primary_record_path() {
  local admin_record_names

  if dscl . -read "/Users/${PRIMARY_ACCOUNT_NAME}" >/dev/null 2>&1; then
    echo "/Users/${PRIMARY_ACCOUNT_NAME}"
    return 0
  fi

  if dscl . -read /Users/admin >/dev/null 2>&1; then
    admin_record_names="$(dscl . -read /Users/admin RecordName 2>/dev/null || true)"
    if grep -Eq "(^|[[:space:]])${PRIMARY_ACCOUNT_NAME}([[:space:]]|$)" <<<"${admin_record_names}" \
      && ! grep -Eq "(^|[[:space:]])admin([[:space:]]|$)" <<<"${admin_record_names}"; then
      echo "/Users/admin"
      return 0
    fi
  fi

  return 1
}

reconcile_primary_home_and_login() {
  local desired_home current_home primary_record_path

  desired_home="/Users/${PRIMARY_ACCOUNT_NAME}"
  if ! primary_record_path="$(resolve_primary_record_path)"; then
    echo "Error: canonical primary account '${PRIMARY_ACCOUNT_NAME}' is missing or still tied to admin alias state." >&2
    exit 1
  fi

  if declare -F dscl_plist_first_attr >/dev/null 2>&1; then
    current_home="$(dscl_plist_first_attr "${primary_record_path}" "NFSHomeDirectory" || true)"
  else
    current_home=""
  fi

  if [[ -z "${current_home}" ]]; then
    current_home="${desired_home}"
  fi

  if [[ "${current_home}" != "${desired_home}" ]]; then
    if [[ -d "${current_home}" && ! -e "${desired_home}" ]]; then
      sudo mv "${current_home}" "${desired_home}" || true
    fi
    sudo dscl . -create "${primary_record_path}" NFSHomeDirectory "${desired_home}" || true
  fi

  # Keep canonical full-name metadata in sync with the resolved primary record.
  sudo dscl . -create "${primary_record_path}" RealName "${PRIMARY_ACCOUNT_FULL_NAME}" || true

  sudo defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser "${AUTO_LOGIN_USER}"
  sudo defaults write /Library/Preferences/com.apple.loginwindow SHOWFULLNAME -bool false || true
  sudo defaults write /Library/Preferences/com.apple.loginwindow Hide500Users -bool false || true
  sudo sh -c "mkdir -p /etc/sudoers.d/; echo '${PRIMARY_ACCOUNT_NAME} ALL=(ALL) NOPASSWD: ALL' | EDITOR=tee visudo /etc/sudoers.d/${PRIMARY_ACCOUNT_NAME}-nopasswd"
}

ensure_primary_admin_membership() {
  local is_member

  is_member="$(dseditgroup -o checkmember -m "${PRIMARY_ACCOUNT_NAME}" admin 2>/dev/null || true)"
  if ! grep -qi "yes" <<<"${is_member}"; then
    echo "Ensuring admin group membership for ${PRIMARY_ACCOUNT_NAME}."
    sudo dseditgroup -o edit -a "${PRIMARY_ACCOUNT_NAME}" -t user admin || true
  fi
}

ensure_primary_secure_token() {
  local token_status system_admin_token_status

  token_status="$(sysadminctl -secureTokenStatus "${PRIMARY_ACCOUNT_NAME}" 2>&1 || true)"
  if grep -qi "ENABLED" <<<"${token_status}" && [[ "${PRIMARY_SECURE_TOKEN_REFRESH}" != "1" ]]; then
    echo "SecureToken already enabled for ${PRIMARY_ACCOUNT_NAME}."
    return 0
  fi

  if grep -qi "ENABLED" <<<"${token_status}"; then
    echo "SecureToken already enabled for ${PRIMARY_ACCOUNT_NAME}; forcing refresh using ${SYSTEM_ADMIN_NAME}."
  else
    echo "Warning: SecureToken not enabled for ${PRIMARY_ACCOUNT_NAME}; attempting recovery using ${SYSTEM_ADMIN_NAME}."
  fi

  if ! dscl . -read "/Users/${SYSTEM_ADMIN_NAME}" >/dev/null 2>&1; then
    echo "Warning: token-authority admin user '${SYSTEM_ADMIN_NAME}' is missing; skipping SecureToken recovery for ${PRIMARY_ACCOUNT_NAME}." >&2
    return 0
  fi

  system_admin_token_status="$(sysadminctl -secureTokenStatus "${SYSTEM_ADMIN_NAME}" 2>&1 || true)"
  if ! grep -qi "ENABLED" <<<"${system_admin_token_status}"; then
    echo "Warning: token-authority admin user '${SYSTEM_ADMIN_NAME}' does not have SecureToken enabled; skipping SecureToken recovery for ${PRIMARY_ACCOUNT_NAME}." >&2
    return 0
  fi

  sysadminctl -adminUser "${SYSTEM_ADMIN_NAME}" -adminPassword "${SYSTEM_ADMIN_PASSWORD}" -secureTokenOn "${PRIMARY_ACCOUNT_NAME}" -password "${PRIMARY_ACCOUNT_PASSWORD}" >/dev/null 2>&1 || true

  token_status="$(sysadminctl -secureTokenStatus "${PRIMARY_ACCOUNT_NAME}" 2>&1 || true)"
  if grep -qi "ENABLED" <<<"${token_status}"; then
    echo "SecureToken enabled for ${PRIMARY_ACCOUNT_NAME}."
  else
    echo "Warning: unable to ensure SecureToken for ${PRIMARY_ACCOUNT_NAME}. Some protected system workflows may still fail until manually repaired." >&2
  fi
}

verify_primary_uid() {
  local uid effective_record_path

  if [[ "${PRIMARY_ACCOUNT_EXPECTED_UID}" -le 0 ]]; then
    echo "Skipping primary UID validation (PRIMARY_ACCOUNT_EXPECTED_UID=${PRIMARY_ACCOUNT_EXPECTED_UID})."
    return 0
  fi

  if ! effective_record_path="$(resolve_primary_record_path)"; then
    echo "Error: unable to resolve effective record path for primary account '${PRIMARY_ACCOUNT_NAME}'." >&2
    exit 1
  fi

  if declare -F dscl_plist_first_attr >/dev/null 2>&1; then
    uid="$(dscl_plist_first_attr "${effective_record_path}" "UniqueID" || true)"
  else
    uid=""
  fi

  if [[ -z "${uid}" ]]; then
    uid="$(id -u "${PRIMARY_ACCOUNT_NAME}" 2>/dev/null || true)"
  fi
  if [[ -z "${uid}" ]]; then
    echo "Error: unable to resolve UID for primary account '${PRIMARY_ACCOUNT_NAME}'." >&2
    exit 1
  fi

  if [[ "${uid}" != "${PRIMARY_ACCOUNT_EXPECTED_UID}" ]]; then
    echo "Error: UID mismatch for '${PRIMARY_ACCOUNT_NAME}': expected ${PRIMARY_ACCOUNT_EXPECTED_UID}, got ${uid}." >&2
    exit 1
  fi

  echo "Primary UID validation passed: ${PRIMARY_ACCOUNT_NAME} -> ${uid} (record=${effective_record_path})"
}

verify_primary_account_state() {
  local effective_record_path desired_home effective_home effective_full_name token_status line

  if ! effective_record_path="$(resolve_primary_record_path)"; then
    echo "Error: unable to resolve effective record path for primary account '${PRIMARY_ACCOUNT_NAME}'." >&2
    exit 1
  fi

  desired_home="/Users/${PRIMARY_ACCOUNT_NAME}"
  if declare -F dscl_plist_first_attr >/dev/null 2>&1; then
    effective_home="$(dscl_plist_first_attr "${effective_record_path}" "NFSHomeDirectory" || true)"
  else
    effective_home=""
  fi
  if [[ -z "${effective_home}" ]]; then
    echo "Error: missing NFSHomeDirectory for '${PRIMARY_ACCOUNT_NAME}' (record=${effective_record_path})." >&2
    exit 1
  fi
  if [[ "${effective_home}" != "${desired_home}" ]]; then
    echo "Error: NFSHomeDirectory mismatch for '${PRIMARY_ACCOUNT_NAME}': expected '${desired_home}', got '${effective_home}' (record=${effective_record_path})." >&2
    exit 1
  fi

  if declare -F dscl_user_real_name >/dev/null 2>&1; then
    effective_full_name=""
    while IFS= read -r line; do
      [[ -z "${line}" ]] && continue
      effective_full_name="${effective_full_name:+${effective_full_name} }${line}"
    done < <(dscl_plist_attr_values "${effective_record_path}" "RealName" || true)
  else
    effective_full_name=""
  fi
  if [[ -z "${effective_full_name}" ]]; then
    echo "Error: missing RealName for '${PRIMARY_ACCOUNT_NAME}' (record=${effective_record_path})." >&2
    exit 1
  fi
  if [[ "${effective_full_name}" != "${PRIMARY_ACCOUNT_FULL_NAME}" ]]; then
    echo "Error: RealName mismatch for '${PRIMARY_ACCOUNT_NAME}': expected '${PRIMARY_ACCOUNT_FULL_NAME}', got '${effective_full_name}' (record=${effective_record_path})." >&2
    exit 1
  fi

  token_status="$(sysadminctl -secureTokenStatus "${PRIMARY_ACCOUNT_NAME}" 2>&1 || true)"
  if ! grep -qi "ENABLED" <<<"${token_status}"; then
    echo "Error: SecureToken is not enabled for '${PRIMARY_ACCOUNT_NAME}' after reconciliation." >&2
    exit 1
  fi

  echo "Primary account state verification passed: user=${PRIMARY_ACCOUNT_NAME}, home=${effective_home}, full_name='${effective_full_name}', token=ENABLED"
}

verify_legacy_admin_absent() {
  if [[ "${PRIMARY_ACCOUNT_NAME}" == "admin" ]]; then
    return 0
  fi

  if dscl . -read /Users/admin >/dev/null 2>&1; then
    echo "Error: legacy '/Users/admin' account record still exists after primary reconciliation; refusing ambiguous primary state." >&2
    exit 1
  fi

  echo "Verified legacy admin account record is absent."
}

delete_legacy_admin_record() {
  if [[ "${PRIMARY_ACCOUNT_NAME}" == "admin" ]]; then
    return 0
  fi

  if dscl . -read /Users/admin >/dev/null 2>&1; then
    echo "Removing legacy admin account record now that primary reconciliation is complete."
    sudo dscl . -delete /Users/admin >/dev/null 2>&1 || true
  fi
}

create_primary_account_from_admin() {
  local old_home desired_home target_uid existing_record_names admin_uid spare_uid

  desired_home="/Users/${PRIMARY_ACCOUNT_NAME}"
  if declare -F dscl_plist_first_attr >/dev/null 2>&1; then
    old_home="$(dscl_plist_first_attr "/Users/admin" "NFSHomeDirectory" || true)"
  else
    old_home=""
  fi
  if [[ -z "${old_home}" ]]; then
    old_home="/Users/admin"
  fi

  target_uid="${PRIMARY_ACCOUNT_EXPECTED_UID}"
  if [[ -z "${target_uid}" || "${target_uid}" -le 0 ]]; then
    if declare -F dscl_plist_first_attr >/dev/null 2>&1; then
      target_uid="$(dscl_plist_first_attr "/Users/admin" "UniqueID" || true)"
    fi
  fi
  if [[ -z "${target_uid}" || "${target_uid}" -le 0 ]]; then
    target_uid="501"
  fi

  if [[ "${old_home}" != "${desired_home}" ]]; then
    if [[ -d "${old_home}" && ! -e "${desired_home}" ]]; then
      sudo mv "${old_home}" "${desired_home}" || true
    fi
  fi

  if declare -F dscl_plist_first_attr >/dev/null 2>&1; then
    admin_uid="$(dscl_plist_first_attr "/Users/admin" "UniqueID" || true)"
  else
    admin_uid=""
  fi
  if [[ -n "${admin_uid}" && "${admin_uid}" == "${target_uid}" ]]; then
    spare_uid=502
    while dscl . -list /Users UniqueID 2>/dev/null | tr -s ' ' | cut -d ' ' -f2 | grep -qx "${spare_uid}"; do
      spare_uid=$((spare_uid + 1))
    done
    echo "Reassigning legacy admin UID from ${admin_uid} to ${spare_uid} so ${PRIMARY_ACCOUNT_NAME} can take UID ${target_uid}."
    sudo dscl . -create /Users/admin UniqueID "${spare_uid}" || true
  fi

  sudo sysadminctl -addUser "${PRIMARY_ACCOUNT_NAME}" \
    -fullName "${PRIMARY_ACCOUNT_FULL_NAME}" \
    -home "${desired_home}" \
    -UID "${target_uid}" \
    -password "${PRIMARY_ACCOUNT_PASSWORD}" \
    -admin || true

  if ! dscl . -read "/Users/${PRIMARY_ACCOUNT_NAME}" >/dev/null 2>&1; then
    echo "Error: failed to create primary account '${PRIMARY_ACCOUNT_NAME}' after deleting admin." >&2
    exit 1
  fi

  sudo mkdir -p "${desired_home}"
  sudo chown -R "${PRIMARY_ACCOUNT_NAME}:staff" "${desired_home}" >/dev/null 2>&1 || true
  sudo dscl . -create "/Users/${PRIMARY_ACCOUNT_NAME}" NFSHomeDirectory "${desired_home}" || true
  sudo dscl . -create "/Users/${PRIMARY_ACCOUNT_NAME}" RealName "${PRIMARY_ACCOUNT_FULL_NAME}" || true

  if [[ -n "${PRIMARY_ACCOUNT_ALIAS}" && "${PRIMARY_ACCOUNT_ALIAS}" != "${PRIMARY_ACCOUNT_NAME}" ]]; then
    existing_record_names="$(dscl . -read "/Users/${PRIMARY_ACCOUNT_NAME}" RecordName 2>/dev/null || true)"
    if ! grep -Eq "(^|[[:space:]])${PRIMARY_ACCOUNT_ALIAS}([[:space:]]|$)" <<<"${existing_record_names}"; then
      sudo dscl . -append "/Users/${PRIMARY_ACCOUNT_NAME}" RecordName "${PRIMARY_ACCOUNT_ALIAS}" || true
    fi
  fi
}

if [[ "${MACOS_BUILD_SOURCE_MODE}" != "clone" ]]; then
  echo "Skipping account short-name migration: build source mode is '${MACOS_BUILD_SOURCE_MODE}' (only applies to clone)."
  ensure_primary_admin_membership
  ensure_primary_secure_token
  verify_primary_uid
  verify_primary_account_state
  verify_legacy_admin_absent
  exit 0
fi

if [[ "${PRIMARY_ACCOUNT_NAME}" == "admin" ]]; then
  echo "Skipping account short-name migration: PRIMARY_ACCOUNT_NAME is already 'admin'."
  ensure_primary_admin_membership
  ensure_primary_secure_token
  verify_primary_uid
  verify_primary_account_state
  verify_legacy_admin_absent
  exit 0
fi

if dscl . -read "/Users/${PRIMARY_ACCOUNT_NAME}" >/dev/null 2>&1; then
  echo "Target account '${PRIMARY_ACCOUNT_NAME}' already exists; reconciling home/login metadata."
  reconcile_primary_home_and_login
  ensure_primary_admin_membership
  ensure_primary_secure_token
  verify_primary_uid
  verify_primary_account_state
  delete_legacy_admin_record
  verify_legacy_admin_absent
  exit 0
fi

if ! dscl . -read /Users/admin >/dev/null 2>&1; then
  echo "Warning: source account 'admin' not found; cannot rename to '${PRIMARY_ACCOUNT_NAME}'."
  exit 0
fi

create_primary_account_from_admin

reconcile_primary_home_and_login
ensure_primary_admin_membership
ensure_primary_secure_token

verify_primary_uid
verify_primary_account_state
delete_legacy_admin_record
verify_legacy_admin_absent

echo "Primary account rename complete for clone mode: admin -> ${PRIMARY_ACCOUNT_NAME}"
