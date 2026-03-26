#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Unlock currently locked external APFS volumes.

Usage:
  unlock-external-apfs-volumes.sh [--dry-run] [--user <disk|UUID>] [--verify]

Options:
  --dry-run         Show which volumes would be unlocked, do not unlock.
  --user <value>    Forward to diskutil apfs unlockVolume -user <value>.
  --verify          Use diskutil unlock verify mode (no mount side-effects).
  -h, --help        Show this help.

Notes:
  - The script only targets APFS volumes that are both:
      1) FileVault/Encryption state: Locked
      2) External/removable (Internal=false)
  - Unlock is interactive by default (no passphrase stored in script history).
USAGE
}

DRY_RUN=0
VERIFY=0
USER_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --verify)
      VERIFY=1
      shift
      ;;
    --user)
      [[ $# -lt 2 ]] && { echo "Missing value for --user" >&2; exit 2; }
      USER_ARG="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

apfs_json="$(diskutil apfs list -plist | plutil -convert json -o - -- -)"

locked_all=()
while IFS= read -r vol; do
  [[ -n "$vol" ]] || continue
  locked_all+=("$vol")
done < <(
  printf '%s\n' "$apfs_json" |
    yq -p json -r '.Containers[].Volumes[] | select(.Locked == true) | .DeviceIdentifier' |
    awk '!seen[$0]++'
)

if [[ ${#locked_all[@]} -eq 0 ]]; then
  echo "No locked APFS volumes found."
  exit 0
fi

locked_external=()
for vol in "${locked_all[@]}"; do
  info_json="$(diskutil info -plist "/dev/${vol}" | plutil -convert json -o - -- - 2>/dev/null || true)"
  if [[ -z "$info_json" ]]; then
    continue
  fi
  internal="$(printf '%s\n' "$info_json" | yq -p json -r '.Internal // "unknown"')"
  if [[ "$internal" == "false" ]]; then
    locked_external+=("$vol")
  fi
done

if [[ ${#locked_external[@]} -eq 0 ]]; then
  echo "No locked external APFS volumes found."
  exit 0
fi

echo "Locked external APFS volumes:"
for vol in "${locked_external[@]}"; do
  info_json="$(diskutil info -plist "/dev/${vol}" | plutil -convert json -o - -- - 2>/dev/null || true)"
  name="$(printf '%s\n' "$info_json" | yq -p json -r '.VolumeName // "(unknown)"')"
  echo "  - /dev/${vol}  (${name})"
done

if [[ "$DRY_RUN" == "1" ]]; then
  echo "Dry run: no unlock operations performed."
  exit 0
fi

echo
for vol in "${locked_external[@]}"; do
  echo "Unlocking /dev/${vol} ..."
  cmd=(diskutil apfs unlockVolume "/dev/${vol}")
  if [[ -n "$USER_ARG" ]]; then
    cmd+=( -user "$USER_ARG" )
  fi
  if [[ "$VERIFY" == "1" ]]; then
    cmd+=( -verify )
  fi

  if "${cmd[@]}"; then
    echo "  OK: /dev/${vol}"
  else
    echo "  FAILED: /dev/${vol}" >&2
  fi

done
