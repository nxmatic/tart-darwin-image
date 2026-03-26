#!/usr/bin/env bash

dscl_plist_attr_values() {
  local record_path="$1"
  local attr_name="$2"

  # Parse plain `dscl -read` output to avoid requiring python3/CLT in guest.
  # Supported shapes:
  #   Attr: value
  #   Attr:
  #    value1
  #    value2
  dscl . -read "${record_path}" "${attr_name}" 2>/dev/null \
    | awk -v attr="${attr_name}" '
      BEGIN {
        in_attr = 0
      }
      {
        if ($0 ~ ("^" attr ":")) {
          in_attr = 1
          line = $0
          sub("^" attr ":[[:space:]]*", "", line)
          if (length(line) > 0) {
            print line
          }
          next
        }

        if (!in_attr) {
          next
        }

        # Stop when another top-level key starts.
        if ($0 ~ /^[^[:space:]]/) {
          exit
        }

        line = $0
        sub(/^[[:space:]]+/, "", line)
        if (length(line) > 0) {
          print line
        }
      }
    '
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
