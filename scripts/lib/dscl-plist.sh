#!/usr/bin/env bash

dscl_plist_attr_values() {
  local record_path="$1"
  local attr_name="$2"

  if ! command -v python3 >/dev/null 2>&1; then
    return 1
  fi

  dscl . -read -plist "${record_path}" "${attr_name}" 2>/dev/null \
    | python3 - "${attr_name}" <<'PY'
import plistlib
import sys

attr = sys.argv[1]
key = f"dsAttrTypeStandard:{attr}"

try:
    payload = plistlib.load(sys.stdin.buffer)
except Exception:
    raise SystemExit(0)

values = payload.get(key, [])
if isinstance(values, list):
    for value in values:
        if value is None:
            continue
        if isinstance(value, bytes):
            try:
                value = value.decode()
            except Exception:
                value = str(value)
        print(str(value))
elif values is not None:
    print(str(values))
PY
}

dscl_plist_first_attr() {
  local record_path="$1"
  local attr_name="$2"

  dscl_plist_attr_values "${record_path}" "${attr_name}" | head -n 1
}

dscl_user_home_dir() {
  local user_name="$1"
  local home_dir

  home_dir="$(dscl_plist_first_attr "/Users/${user_name}" "NFSHomeDirectory" 2>/dev/null || true)"
  if [[ -n "${home_dir}" ]]; then
    printf '%s\n' "${home_dir}"
    return 0
  fi

  printf '/Users/%s\n' "${user_name}"
}

dscl_user_unique_id() {
  local user_name="$1"
  dscl_plist_first_attr "/Users/${user_name}" "UniqueID" 2>/dev/null || true
}

dscl_user_real_name() {
  local user_name="$1"
  local line
  local full_name=""

  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    full_name="${full_name:+${full_name} }${line}"
  done < <(dscl_plist_attr_values "/Users/${user_name}" "RealName" 2>/dev/null || true)

  printf '%s\n' "${full_name}"
}
