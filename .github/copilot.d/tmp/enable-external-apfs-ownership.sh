#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Set APFS ownership policy for cross-host access, safely.

Usage:
  enable-external-apfs-ownership.sh [--dry-run] [--image <path.asif>]... [--all-roles]
                                   [--ownership-mode disable|enable] [--include-system-mounts]

Modes:
  1) No --image: operate on currently attached external APFS volumes.
  2) With --image: attach each ASIF, process APFS volumes, then detach.

Options:
  --dry-run         Show planned actions only; do not modify state.
  --image <path>    ASIF image path to process (repeatable).
  --all-roles       Include APFS volumes with explicit roles (default: roleless only).
  --ownership-mode  Ownership policy to apply. Default: disable (portable access).
                    disable => diskutil disableOwnership
                    enable  => diskutil enableOwnership
  --include-system-mounts
                    Include mounted volumes outside default allowed prefixes.
  -h, --help        Show this help.

Notes:
  - Uses: diskutil + plutil + yq.
  - Skips locked volumes.
  - Default allowed mount prefixes are:
      /Volumes
      /nix
      /private/var/lib/git
    These cover your role disks while avoiding most OS/system mounts.
  - Runs diskutil ownership command only when a change is needed.
  - Requires sudo/root to actually apply ownership changes.
USAGE
}

DRY_RUN=0
IMAGES=()
ALL_ROLES=0
INCLUDE_SYSTEM_MOUNTS=0
OWNERSHIP_MODE="disable"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --image)
      [[ $# -lt 2 ]] && { echo "Missing value for --image" >&2; exit 2; }
      IMAGES+=("$2")
      shift 2
      ;;
    --all-roles)
      ALL_ROLES=1
      shift
      ;;
    --ownership-mode)
      [[ $# -lt 2 ]] && { echo "Missing value for --ownership-mode" >&2; exit 2; }
      OWNERSHIP_MODE="$2"
      if [[ "$OWNERSHIP_MODE" != "disable" && "$OWNERSHIP_MODE" != "enable" ]]; then
        echo "Invalid --ownership-mode '$OWNERSHIP_MODE' (expected disable|enable)" >&2
        exit 2
      fi
      shift 2
      ;;
    --include-system-mounts)
      INCLUDE_SYSTEM_MOUNTS=1
      shift
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

log() { printf '%s\n' "$*"; }

volume_info_json() {
  local dev="$1"
  diskutil info -plist "$dev" | plutil -convert json -o - -- -
}

process_volume() {
  local dev="$1"
  local info_json internal external_hint removable bus fs locked owners name mount_point is_external desired_owners

  info_json="$(volume_info_json "$dev" 2>/dev/null || true)"
  [[ -n "$info_json" ]] || { log "skip $dev: unable to read diskutil info"; return 0; }

  internal="$(printf '%s\n' "$info_json" | yq -p json -r '.Internal // "unknown"')"
  external_hint="$(printf '%s\n' "$info_json" | yq -p json -r '.RemovableMediaOrExternalDevice // false')"
  removable="$(printf '%s\n' "$info_json" | yq -p json -r '.Removable // false')"
  bus="$(printf '%s\n' "$info_json" | yq -p json -r '.BusProtocol // ""')"
  fs="$(printf '%s\n' "$info_json" | yq -p json -r '.FilesystemType // ""')"
  locked="$(printf '%s\n' "$info_json" | yq -p json -r '.Locked // false')"
  owners="$(printf '%s\n' "$info_json" | yq -p json -r '.GlobalPermissionsEnabled // "unknown"')"
  name="$(printf '%s\n' "$info_json" | yq -p json -r '.VolumeName // .MediaName // "(unknown)"')"
  mount_point="$(printf '%s\n' "$info_json" | yq -p json -r '.MountPoint // ""')"

  [[ "$fs" == "apfs" ]] || { log "skip $dev ($name): fs=$fs"; return 0; }

  if [[ "$INCLUDE_SYSTEM_MOUNTS" != "1" && -n "$mount_point" && "$mount_point" != "null" ]]; then
    if [[ "$mount_point" != /Volumes/* && "$mount_point" != /nix* && "$mount_point" != /private/var/lib/git* ]]; then
      log "skip $dev ($name): mounted outside allowed prefixes '$mount_point'"
      return 0
    fi
  fi

  [[ "$locked" != "true" ]] || { log "skip $dev ($name): locked"; return 0; }

  is_external=0
  if [[ "$internal" == "false" || "$external_hint" == "true" || "$removable" == "true" || "$bus" == "Disk Image" ]]; then
    is_external=1
  fi

  log "target $dev ($name): mount='${mount_point:-not-mounted}' owners=$owners external=$is_external"

  if [[ -z "$mount_point" || "$mount_point" == "null" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
      log "  dry-run: would mount $dev"
    else
      diskutil mount "$dev" >/dev/null
      log "  mounted $dev"
    fi
  fi

  desired_owners="false"
  if [[ "$OWNERSHIP_MODE" == "enable" ]]; then
    desired_owners="true"
  fi

  if [[ "$owners" == "$desired_owners" ]]; then
    log "  owners already ${OWNERSHIP_MODE}d"
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    if [[ "$OWNERSHIP_MODE" == "disable" ]]; then
      log "  dry-run: would run sudo diskutil disableOwnership $dev"
    else
      log "  dry-run: would run sudo diskutil enableOwnership $dev"
    fi
    return 0
  fi

  if [[ "$OWNERSHIP_MODE" == "disable" ]]; then
    sudo diskutil disableOwnership "$dev" >/dev/null
  else
    sudo diskutil enableOwnership "$dev" >/dev/null
  fi

  # Re-read and report final state
  info_json="$(volume_info_json "$dev" 2>/dev/null || true)"
  owners="$(printf '%s\n' "$info_json" | yq -p json -r '.GlobalPermissionsEnabled // "unknown"')"
  log "  owners now: $owners"
}

process_attached_external_apfs() {
  local apfs_json dev query
  apfs_json="$(diskutil apfs list -plist | plutil -convert json -o - -- -)"
  query='.Containers[].Volumes[].DeviceIdentifier'
  if [[ "$ALL_ROLES" != "1" ]]; then
    query='.Containers[].Volumes[] | select((.Roles // [] | length) == 0) | .DeviceIdentifier'
  fi
  while IFS= read -r dev; do
    [[ -n "$dev" ]] || continue
    process_volume "/dev/${dev}"
  done < <(
    printf '%s\n' "$apfs_json" |
      yq -p json -r "$query" |
      awk '!seen[$0]++'
  )
}

process_image() {
  local image="$1"
  local attach_json base_dev volumes v

  [[ -f "$image" ]] || { log "skip image: not found: $image"; return 0; }

  attach_json="$(diskutil image attach -nomount -nobrowse -plist "$image" | plutil -convert json -o - -- -)"
  base_dev="$(printf '%s\n' "$attach_json" | yq -p json -r '."system-entities"[] | select(has("dev-entry")) | ."dev-entry" | select(test("^(/dev/)?disk[0-9]+$"))' | awk 'NR==1{print}')"
  base_dev="/dev/${base_dev#/dev/}"

  volumes="$(printf '%s\n' "$attach_json" | yq -p json -r '."system-entities"[] | select(has("dev-entry")) | select((."filesystem-type" == "apfs") or (."content-hint" == "Apple_APFS_Volume")) | ."dev-entry" | select(test("^(/dev/)?disk[0-9]+s[0-9]+$"))' | awk '!seen[$0]++')"

  if [[ -z "$volumes" ]]; then
    log "no APFS volumes found in image: $image"
    diskutil image detach "$base_dev" >/dev/null 2>&1 || true
    return 0
  fi

  log "image: $image (base=$base_dev)"
  while IFS= read -r v; do
    [[ -n "$v" ]] || continue
    process_volume "/dev/${v#/dev/}"
  done <<< "$volumes"

  if [[ "$DRY_RUN" == "1" ]]; then
    log "dry-run: would detach $base_dev"
  else
    diskutil image detach "$base_dev" >/dev/null || true
    log "detached $base_dev"
  fi
}

if [[ ${#IMAGES[@]} -eq 0 ]]; then
  process_attached_external_apfs
else
  for img in "${IMAGES[@]}"; do
    process_image "$img"
  done
fi
