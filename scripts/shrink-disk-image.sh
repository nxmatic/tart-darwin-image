#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  shrink-disk-image.sh --source-image <path.asif> --target-size-gb <N> [options]

Generic host-side shrink helper for Tart/macOS ASIF disk images.
This works for any image path (not tied to a specific disk role).

Required:
  --source-image <path>       Existing image to shrink.
  --target-size-gb <N>        Size in GiB for newly created target image.

Optional:
  --target-image <path>       Path for new image (default: <source>.new.asif).
  --target-volume-name <name> APFS volume name for new image (default: Shrunk Disk).
  --reuse-target              Reuse existing --target-image instead of creating it.
  --replace-source            Replace source file with target on success (keeps backup).
  --backup-suffix <suffix>    Backup suffix when --replace-source is used.
  --no-delete                 Do not pass --delete to rsync.
  --dry-run                   Print plan and exit.
  -h, --help                  Show this help.

Examples:
  shrink-disk-image.sh \
    --source-image ~/.tart/disks/myvm/nix-store.asif \
    --target-size-gb 120

  shrink-disk-image.sh \
    --source-image ~/.tart/disks/myvm/user-data.asif \
    --target-size-gb 96 \
    --replace-source
EOF
}

log() {
  printf '[shrink-disk-image] %s\n' "$*"
}

die() {
  printf '[shrink-disk-image] ERROR: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

SOURCE_IMAGE=""
TARGET_IMAGE=""
TARGET_SIZE_GB=""
TARGET_VOLUME_NAME="Shrunk Disk"
REUSE_TARGET=0
REPLACE_SOURCE=0
RSYNC_DELETE=1
DRY_RUN=0
BACKUP_SUFFIX="$(date +%Y%m%d-%H%M%S).bak"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-image)
      SOURCE_IMAGE="$2"
      shift 2
      ;;
    --target-image)
      TARGET_IMAGE="$2"
      shift 2
      ;;
    --target-size-gb)
      TARGET_SIZE_GB="$2"
      shift 2
      ;;
    --target-volume-name)
      TARGET_VOLUME_NAME="$2"
      shift 2
      ;;
    --reuse-target)
      REUSE_TARGET=1
      shift
      ;;
    --replace-source)
      REPLACE_SOURCE=1
      shift
      ;;
    --backup-suffix)
      BACKUP_SUFFIX="$2"
      shift 2
      ;;
    --no-delete)
      RSYNC_DELETE=0
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

[[ -n "${SOURCE_IMAGE}" ]] || die "--source-image is required"
[[ -n "${TARGET_SIZE_GB}" ]] || die "--target-size-gb is required"
[[ "${TARGET_SIZE_GB}" =~ ^[0-9]+$ ]] || die "--target-size-gb must be an integer"

SOURCE_IMAGE="$(realpath "${SOURCE_IMAGE}")"
[[ -f "${SOURCE_IMAGE}" ]] || die "Source image not found: ${SOURCE_IMAGE}"

if [[ -z "${TARGET_IMAGE}" ]]; then
  src_dir="$(dirname "${SOURCE_IMAGE}")"
  src_base="$(basename "${SOURCE_IMAGE}")"
  src_name="${src_base%.asif}"
  TARGET_IMAGE="${src_dir}/${src_name}.new.asif"
fi
TARGET_IMAGE="$(realpath "$(dirname "${TARGET_IMAGE}")")/$(basename "${TARGET_IMAGE}")"

require_cmd hdiutil
require_cmd diskutil
require_cmd rsync
require_cmd du
require_cmd df

if [[ "${DRY_RUN}" == "1" ]]; then
  log "Dry-run plan"
  log "  source image      : ${SOURCE_IMAGE}"
  log "  target image      : ${TARGET_IMAGE}"
  log "  target size (GiB) : ${TARGET_SIZE_GB}"
  log "  target vol name   : ${TARGET_VOLUME_NAME}"
  log "  reuse target      : ${REUSE_TARGET}"
  log "  replace source    : ${REPLACE_SOURCE}"
  log "  rsync --delete    : ${RSYNC_DELETE}"
  log "  backup suffix     : ${BACKUP_SUFFIX}"
  exit 0
fi

if [[ -e "${TARGET_IMAGE}" && "${REUSE_TARGET}" != "1" ]]; then
  die "Target image exists; remove it or use --reuse-target: ${TARGET_IMAGE}"
fi

if [[ ! -e "${TARGET_IMAGE}" ]]; then
  log "Creating target image: ${TARGET_IMAGE} (${TARGET_SIZE_GB}G)"
  mkdir -p "$(dirname "${TARGET_IMAGE}")"
  diskutil image create blank --format ASIF --size "${TARGET_SIZE_GB}G" --volumeName "${TARGET_VOLUME_NAME}" "${TARGET_IMAGE}"
else
  log "Reusing target image: ${TARGET_IMAGE}"
fi

SRC_MNT="$(mktemp -d /tmp/shrink-src.XXXXXX)"
DST_MNT="$(mktemp -d /tmp/shrink-dst.XXXXXX)"
SRC_ATTACHED=0
DST_ATTACHED=0

cleanup() {
  set +e
  if [[ "${DST_ATTACHED}" == "1" ]]; then
    hdiutil detach "${DST_MNT}" >/dev/null 2>&1 || true
  fi
  if [[ "${SRC_ATTACHED}" == "1" ]]; then
    hdiutil detach "${SRC_MNT}" >/dev/null 2>&1 || true
  fi
  rm -rf "${SRC_MNT}" "${DST_MNT}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

log "Attaching source image"
hdiutil attach -nobrowse -noverify -noautoopen -owners on -mountpoint "${SRC_MNT}" "${SOURCE_IMAGE}" >/dev/null
SRC_ATTACHED=1

log "Attaching target image"
hdiutil attach -nobrowse -noverify -noautoopen -owners on -mountpoint "${DST_MNT}" "${TARGET_IMAGE}" >/dev/null
DST_ATTACHED=1

source_used_kb="$(du -sk "${SRC_MNT}" | awk '{print $1}')"
target_avail_kb="$(df -k "${DST_MNT}" | awk 'NR==2 {print $4}')"

if [[ -z "${source_used_kb}" || -z "${target_avail_kb}" ]]; then
  die "Unable to determine source usage or target availability"
fi

if (( source_used_kb > target_avail_kb )); then
  die "Target appears too small: source uses ${source_used_kb} KB, target available ${target_avail_kb} KB"
fi

log "Copying data from source to target"
RSYNC_ARGS=(-aE --human-readable --info=progress2)
if [[ "${RSYNC_DELETE}" == "1" ]]; then
  RSYNC_ARGS+=(--delete)
fi
rsync "${RSYNC_ARGS[@]}" "${SRC_MNT}/" "${DST_MNT}/"

log "Syncing copied data"
sync

log "Detaching images"
hdiutil detach "${DST_MNT}" >/dev/null
DST_ATTACHED=0
hdiutil detach "${SRC_MNT}" >/dev/null
SRC_ATTACHED=0

if [[ "${REPLACE_SOURCE}" == "1" ]]; then
  src_dir="$(dirname "${SOURCE_IMAGE}")"
  src_base="$(basename "${SOURCE_IMAGE}")"
  backup_path="${src_dir}/${src_base}.${BACKUP_SUFFIX}"

  [[ ! -e "${backup_path}" ]] || die "Backup path already exists: ${backup_path}"

  log "Replacing source image"
  mv "${SOURCE_IMAGE}" "${backup_path}"
  mv "${TARGET_IMAGE}" "${SOURCE_IMAGE}"

  log "Replacement complete"
  log "  new source: ${SOURCE_IMAGE}"
  log "  backup    : ${backup_path}"
else
  log "Shrink copy complete"
  log "  source: ${SOURCE_IMAGE}"
  log "  target: ${TARGET_IMAGE}"
fi

log "Done"
