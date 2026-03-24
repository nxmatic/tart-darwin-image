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

: "${SYSTEM_CONTAINER_SIZE_GB:=0}"

detect_apfs_container_device() {
  local mount_point container

  # Prefer Data volume first to avoid snapshot/overlay ambiguity on '/'.
  for mount_point in "/System/Volumes/Data" "/"; do
    container=$(diskutil info -plist "$mount_point" 2>/dev/null | plutil -extract APFSContainerReference raw -o - - 2>/dev/null || true)
    if [[ -n "${container:-}" ]]; then
      # Guardrail: only accept container that actually carries System/Data roles.
      if diskutil apfs list "$container" 2>/dev/null | grep -Eq '\(System\)|\(Data\)'; then
        echo "$container"
        return 0
      fi
    fi
  done

  # Fallback by scanning APFS listing for the container with System role.
  container="$(diskutil apfs list 2>/dev/null | awk '
    /^\+-- Container disk/ {
      current = $3
      next
    }
    /\(System\)/ {
      if (current != "") {
        print current
        exit
      }
    }
  ' || true)"
  if [[ -n "${container:-}" ]]; then
    echo "$container"
    return 0
  fi

  return 1
}

print_resize_diagnostics() {
  local container_device="$1"

  echo "--- resize diagnostics begin ---"
  echo "Container target: ${container_device}"
  diskutil info "$container_device" 2>/dev/null || true
  diskutil apfs list "$container_device" 2>/dev/null || true

  # Physical store disk (e.g. disk0s2) and whole disk map (e.g. disk0)
  local physical_store whole_disk
  physical_store="$(diskutil info -plist "$container_device" | plutil -extract APFSPhysicalStores.0.DeviceIdentifier raw -o - - 2>/dev/null || true)"
  if [[ -n "${physical_store:-}" ]]; then
    whole_disk="${physical_store%%s*}"
    echo "Physical store: ${physical_store}"
    echo "Whole disk: ${whole_disk}"
    diskutil list "$whole_disk" 2>/dev/null || true
    diskutil list "$physical_store" 2>/dev/null || true
  fi
  echo "--- resize diagnostics end ---"
}

CONTAINER_DEVICE=$(detect_apfs_container_device || true)

if [[ -z "${CONTAINER_DEVICE:-}" ]]; then
  echo "Unable to detect APFS container device for / or /System/Volumes/Data; skipping resize."
  exit 1
fi

: "Resize detected APFS container only when target is larger; 0 means grow to max"
if [[ "$SYSTEM_CONTAINER_SIZE_GB" -gt 0 ]]; then
  CURRENT_BYTES=$(diskutil info -plist "$CONTAINER_DEVICE" | plutil -extract TotalSize raw -o - - 2>/dev/null || echo 0)
  TARGET_BYTES=$(( SYSTEM_CONTAINER_SIZE_GB * 1024 * 1024 * 1024 ))

  if [[ "$TARGET_BYTES" -gt "$CURRENT_BYTES" ]]; then
    RESIZE_OUTPUT=""
    if ! RESIZE_OUTPUT=$(sudo diskutil apfs resizeContainer "$CONTAINER_DEVICE" "${SYSTEM_CONTAINER_SIZE_GB}g" 2>&1); then
      printf '%s\n' "$RESIZE_OUTPUT"

      if grep -q 'Error: -69743' <<<"$RESIZE_OUTPUT"; then
        echo "Info: ${CONTAINER_DEVICE} already at requested size (${SYSTEM_CONTAINER_SIZE_GB}G); continuing."
      elif grep -q 'Error: -69519' <<<"$RESIZE_OUTPUT"; then
        print_resize_diagnostics "$CONTAINER_DEVICE"
        MAX_BYTES=$(sed -nE 's/.*maximum size[^0-9]*([0-9,]+) bytes.*/\1/p' <<<"$RESIZE_OUTPUT" | head -n1 | tr -d ',')
        if [[ -n "${MAX_BYTES:-}" ]]; then
          MAX_GIB=$(( MAX_BYTES / 1024 / 1024 / 1024 ))
          echo "Warning: requested ${SYSTEM_CONTAINER_SIZE_GB}G for ${CONTAINER_DEVICE}, but maximum supported is ${MAX_GIB}GiB (${MAX_BYTES} bytes). Keeping current size and continuing."
        else
          echo "Warning: requested ${SYSTEM_CONTAINER_SIZE_GB}G for ${CONTAINER_DEVICE}, but diskutil reported size-limit error (-69519). Keeping current size and continuing."
        fi
      else
        echo "Resize failed with an unexpected error; aborting." >&2
        exit 1
      fi
    else
      printf '%s\n' "$RESIZE_OUTPUT"
    fi
  else
    echo "Skipping ${CONTAINER_DEVICE} resize: target (${SYSTEM_CONTAINER_SIZE_GB}G) is not larger than current size."
  fi
else
  RESIZE_OUTPUT=""
  if ! RESIZE_OUTPUT=$(sudo diskutil apfs resizeContainer "$CONTAINER_DEVICE" 0 2>&1); then
    printf '%s\n' "$RESIZE_OUTPUT"
    if grep -q 'Error: -69743' <<<"$RESIZE_OUTPUT"; then
      echo "Info: ${CONTAINER_DEVICE} already at maximum supported size; no growth needed."
    elif grep -q 'Error: -69519' <<<"$RESIZE_OUTPUT"; then
      print_resize_diagnostics "$CONTAINER_DEVICE"
      echo "Warning: ${CONTAINER_DEVICE} hit APFS map limit while growing to max; continuing with current size."
    else
      echo "Resize failed with an unexpected error while growing to max; aborting." >&2
      exit 1
    fi
  else
    printf '%s\n' "$RESIZE_OUTPUT"
  fi
fi
