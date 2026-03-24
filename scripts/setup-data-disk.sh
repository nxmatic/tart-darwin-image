#!/usr/bin/env bash
set -euo pipefail

: "${MACOS_DEBUG_MODE:=1}"
if [[ "${MACOS_DEBUG_MODE}" == "1" ]]; then
  set -x
fi

: "${USER_DATA_DISK_INITIAL_SIZE_GB:=64}"
: "${USER_LIBRARY_DISK_INITIAL_SIZE_GB:=20}"
: "${GIT_BARE_STORE_DISK_INITIAL_SIZE_GB:=4}"
: "${GIT_STORE_DISK_INITIAL_SIZE_GB:=6}"
: "${NIX_STORE_DISK_INITIAL_SIZE_GB:=90}"
: "${BUILD_CHAINS_DISK_INITIAL_SIZE_GB:=16}"
: "${VM_IMAGES_DISK_INITIAL_SIZE_GB:=120}"
: "${DATA_HOME_USER:=${PRIMARY_ACCOUNT_NAME:-nxmatic}}"
: "${DATA_DISK_HOME_NAME:=Data-Home-${DATA_HOME_USER:-nxmatic}}"
: "${DATA_DISK_LIBRARY_CACHE_NAME:=Data Library Cache ${DATA_HOME_USER:-nxmatic}}"
: "${DATA_DISK_VM_IMAGES_NAME:=Data VM Images ${DATA_HOME_USER:-nxmatic}}"
: "${DATA_DISK_BUILD_CHAINS_CACHE_NAME:=Data Build Chains Cache ${DATA_HOME_USER:-nxmatic}}"
: "${DATA_DISK_GIT_STORE_NAME:=Git Store}"
: "${DATA_DISK_GIT_BARE_STORE_NAME:=Git Bare Store}"
: "${DATA_DISK_NIX_STORE_NAME:=Nix Store}"
: "${DATA_HOME_VOLUME_PREFIX:=Data-${DATA_HOME_USER:-nxmatic}}"
: "${DATA_HOME_USERS_SUBVOLUME_PREFIX:=Home}"
: "${DATA_HOME_SYSTEM_SUBVOLUME_NAME:=System}"
: "${DATA_RELOCATE_LIBRARY:=0}"
: "${DATA_HOME_PARENT_DIR:=Users}"
: "${DATA_HOME_ALLOW_FALLBACK_USER:=0}"
: "${DATA_SET_PRIMARY_HOME_ON_DATA_VOLUME:=1}"
: "${DATA_DEFER_USERS_CUTOVER:=1}"
: "${DATA_DEFER_VAR_LIB_CUTOVER:=0}"
: "${DATA_COPY_USER_LIBRARY:=0}"
: "${DATA_COPY_GIT_STORE:=1}"
: "${DATA_COPY_NIX_STORE:=0}"
: "${DATA_COPY_BUILD_CHAINS:=1}"
: "${GIT_STORE_CONFIGURE_SYSTEM_MOUNT:=1}"
: "${GIT_STORE_SYSTEM_MOUNT_POINT:=/private/var/lib/git}"

resolve_data_home_user() {
  local preferred="${DATA_HOME_USER:-}"
  local candidate

  if [[ -n "${preferred}" ]] && dscl . -read "/Users/${preferred}" >/dev/null 2>&1; then
    echo "${preferred}"
    return 0
  fi

  if [[ "${DATA_HOME_ALLOW_FALLBACK_USER}" != "1" ]]; then
    echo "${preferred:-${PRIMARY_ACCOUNT_NAME:-nxmatic}}"
    return 0
  fi

  for candidate in "${PACKER_SSH_USERNAME:-}" "${SUDO_USER:-}" "${USER:-}" admin; do
    if [[ -n "${candidate}" ]] && dscl . -read "/Users/${candidate}" >/dev/null 2>&1; then
      echo "${candidate}"
      return 0
    fi
  done

  echo "admin"
}

resolve_home_dir_for_user() {
  local user="$1"
  local dscl_home

  dscl_home="$(dscl . -read "/Users/${user}" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
  if [[ -n "${dscl_home}" ]]; then
    echo "${dscl_home}"
    return 0
  fi

  echo "/Users/${user}"
}

sanitize_volume_component() {
  local value="$1"
  value="${value//[^a-zA-Z0-9._-]/-}"
  value="${value##-}"
  value="${value%%-}"
  if [[ -z "${value}" ]]; then
    value="default"
  fi
  printf '%s\n' "${value}"
}

get_mount_point_for_volume() {
  local volume_ref="$1"
  local mount_point

  mount_point="$(diskutil info -plist "${volume_ref}" | plutil -extract MountPoint raw -o - - 2>/dev/null || true)"
  if [[ -z "${mount_point}" ]]; then
    mount_point="/Volumes/${volume_ref}"
  fi
  printf '%s\n' "${mount_point}"
}

ensure_apfs_volume() {
  local container_ref="$1"
  local volume_name="$2"

  if ! diskutil info "${volume_name}" >/dev/null 2>&1; then
    sudo diskutil apfs addVolume "${container_ref}" APFS "${volume_name}" >/dev/null
  fi

  sudo diskutil mount "${volume_name}" >/dev/null 2>&1 || true
  get_mount_point_for_volume "${volume_name}"
}

: "Detect secondary physical disks"
DATA_DISKS=()
while IFS= read -r disk; do
  [[ -n "${disk}" ]] && DATA_DISKS+=("${disk}")
done < <(diskutil list physical | awk '/^\/dev\/disk[0-9]+/ { gsub("/dev/", "", $1); print $1 }' | awk '$1 != "disk0" { print }')

if [[ "${#DATA_DISKS[@]}" -eq 0 ]]; then
  echo 'No secondary disks detected during build, skipping data-disk migration.'
  exit 0
fi

DISK_NAMES=(
  "${DATA_DISK_HOME_NAME}"
  "${DATA_DISK_LIBRARY_CACHE_NAME}"
  "${DATA_DISK_GIT_BARE_STORE_NAME}"
  "${DATA_DISK_GIT_STORE_NAME}"
  "${DATA_DISK_NIX_STORE_NAME}"
  "${DATA_DISK_BUILD_CHAINS_CACHE_NAME}"
  "${DATA_DISK_VM_IMAGES_NAME}"
)

if [[ "${#DATA_DISKS[@]}" -lt "${#DISK_NAMES[@]}" ]]; then
  echo "Warning: found ${#DATA_DISKS[@]} secondary disks but ${#DISK_NAMES[@]} logical data disks requested."
  echo "         Missing roles will be skipped for this run."
fi

USER_DATA_MOUNT_POINT=""
USER_LIBRARY_MOUNT_POINT=""
GIT_BARE_STORE_MOUNT_POINT=""
GIT_STORE_DATA_MOUNT_POINT=""
NIX_STORE_MOUNT_POINT=""
BUILD_CHAINS_MOUNT_POINT=""
VM_IMAGES_MOUNT_POINT=""

for idx in "${!DISK_NAMES[@]}"; do
  if [[ "$idx" -ge "${#DATA_DISKS[@]}" ]]; then
    break
  fi

  DATA_DISK="${DATA_DISKS[$idx]}"
  DATA_DISK_LABEL="${DISK_NAMES[$idx]}"
  INITIAL_SIZE_GB=0

  case "${DATA_DISK_LABEL}" in
    "${DATA_DISK_HOME_NAME}") INITIAL_SIZE_GB="${USER_DATA_DISK_INITIAL_SIZE_GB}" ;;
    "${DATA_DISK_LIBRARY_CACHE_NAME}") INITIAL_SIZE_GB="${USER_LIBRARY_DISK_INITIAL_SIZE_GB}" ;;
    "${DATA_DISK_GIT_BARE_STORE_NAME}") INITIAL_SIZE_GB="${GIT_BARE_STORE_DISK_INITIAL_SIZE_GB}" ;;
    "${DATA_DISK_GIT_STORE_NAME}") INITIAL_SIZE_GB="${GIT_STORE_DISK_INITIAL_SIZE_GB}" ;;
    "${DATA_DISK_NIX_STORE_NAME}") INITIAL_SIZE_GB="${NIX_STORE_DISK_INITIAL_SIZE_GB}" ;;
    "${DATA_DISK_BUILD_CHAINS_CACHE_NAME}") INITIAL_SIZE_GB="${BUILD_CHAINS_DISK_INITIAL_SIZE_GB}" ;;
    "${DATA_DISK_VM_IMAGES_NAME}") INITIAL_SIZE_GB="${VM_IMAGES_DISK_INITIAL_SIZE_GB}" ;;
  esac

  echo "Assigning /dev/${DATA_DISK} to '${DATA_DISK_LABEL}'"

  if ! diskutil info "${DATA_DISK_LABEL}" >/dev/null 2>&1; then
    sudo diskutil unmountDisk force "/dev/${DATA_DISK}" >/dev/null 2>&1 || true

    if ! sudo diskutil eraseDisk APFS "${DATA_DISK_LABEL}" GPT "/dev/${DATA_DISK}"; then
      echo "First erase attempt failed for ${DATA_DISK_LABEL}, retrying after force unmount..."
      sudo diskutil unmountDisk force "/dev/${DATA_DISK}" >/dev/null 2>&1 || true
      sleep 2

      if ! sudo diskutil eraseDisk APFS "${DATA_DISK_LABEL}" GPT "/dev/${DATA_DISK}"; then
        echo "Erase failed twice; attempting to use an existing APFS volume on /dev/${DATA_DISK}."

        EXISTING_VOL="$(diskutil list "/dev/${DATA_DISK}" | awk '/Apple_APFS/ {print $NF; exit}' || true)"
        if [[ -n "${EXISTING_VOL:-}" ]]; then
          sudo diskutil rename "${EXISTING_VOL}" "${DATA_DISK_LABEL}" || true
        fi

        if ! diskutil info "${DATA_DISK_LABEL}" >/dev/null 2>&1; then
          echo "Unable to prepare ${DATA_DISK_LABEL} on /dev/${DATA_DISK}." >&2
          continue
        fi
      fi
    fi
  fi

  DATA_VOL_REF="${DATA_DISK_LABEL}"
  if ! diskutil info "${DATA_VOL_REF}" >/dev/null 2>&1; then
    DATA_VOL_REF="$(diskutil list "/dev/${DATA_DISK}" | awk '/Apple_APFS/ {print $NF; exit}' || true)"
  fi
  if [[ -z "${DATA_VOL_REF:-}" ]]; then
    echo "Warning: unable to determine APFS volume for /dev/${DATA_DISK}; skipping role '${DATA_DISK_LABEL}'."
    continue
  fi

  if [[ "$INITIAL_SIZE_GB" -gt 0 ]]; then
    DATA_CONTAINER_DEV=$(diskutil info -plist "${DATA_VOL_REF}" | plutil -extract APFSContainerReference raw -o - - 2>/dev/null || true)
    if [[ -z "${DATA_CONTAINER_DEV:-}" ]]; then
      DATA_CONTAINER_DEV=$(diskutil info "${DATA_VOL_REF}" | awk -F': *' '/APFS Container Reference/ {print $2; exit}' || true)
    fi
    CURRENT_BYTES=$(diskutil info -plist "${DATA_VOL_REF}" | plutil -extract TotalSize raw -o - - 2>/dev/null || echo 0)
    TARGET_BYTES=$(( INITIAL_SIZE_GB * 1024 * 1024 * 1024 ))

    if [[ "$TARGET_BYTES" -ne "$CURRENT_BYTES" ]]; then
      if [[ -n "${DATA_CONTAINER_DEV:-}" ]]; then
        if ! sudo diskutil apfs resizeContainer "$DATA_CONTAINER_DEV" "${INITIAL_SIZE_GB}g"; then
          echo "Warning: resize to ${INITIAL_SIZE_GB}G failed for ${DATA_DISK_LABEL} (${DATA_CONTAINER_DEV}); continuing."
        fi
      else
        echo "Warning: could not resolve APFS container for ${DATA_VOL_REF}; skipping resize."
      fi
    else
      echo "Skipping ${DATA_DISK_LABEL} resize: target (${INITIAL_SIZE_GB}G) already matches current size."
    fi
  fi

  sudo diskutil mount "${DATA_VOL_REF}" || true
  DATA_MOUNT_POINT="$(diskutil info -plist "${DATA_VOL_REF}" | plutil -extract MountPoint raw -o - - 2>/dev/null || true)"
  if [[ -z "${DATA_MOUNT_POINT:-}" ]]; then
    DATA_MOUNT_POINT="/Volumes/${DATA_VOL_REF}"
  fi
  sudo mkdir -p "${DATA_MOUNT_POINT}"

  if [[ "${DATA_DISK_LABEL}" == "${DATA_DISK_HOME_NAME}" ]]; then
    USER_DATA_MOUNT_POINT="${DATA_MOUNT_POINT}"
  elif [[ "${DATA_DISK_LABEL}" == "${DATA_DISK_LIBRARY_CACHE_NAME}" ]]; then
    USER_LIBRARY_MOUNT_POINT="${DATA_MOUNT_POINT}"
  elif [[ "${DATA_DISK_LABEL}" == "${DATA_DISK_GIT_BARE_STORE_NAME}" ]]; then
    GIT_BARE_STORE_MOUNT_POINT="${DATA_MOUNT_POINT}"
  elif [[ "${DATA_DISK_LABEL}" == "${DATA_DISK_GIT_STORE_NAME}" ]]; then
    GIT_STORE_DATA_MOUNT_POINT="${DATA_MOUNT_POINT}"
  elif [[ "${DATA_DISK_LABEL}" == "${DATA_DISK_NIX_STORE_NAME}" ]]; then
    NIX_STORE_MOUNT_POINT="${DATA_MOUNT_POINT}"
  elif [[ "${DATA_DISK_LABEL}" == "${DATA_DISK_BUILD_CHAINS_CACHE_NAME}" ]]; then
    BUILD_CHAINS_MOUNT_POINT="${DATA_MOUNT_POINT}"
  elif [[ "${DATA_DISK_LABEL}" == "${DATA_DISK_VM_IMAGES_NAME}" ]]; then
    VM_IMAGES_MOUNT_POINT="${DATA_MOUNT_POINT}"
  fi
done

DATA_MOUNT_POINT="${USER_DATA_MOUNT_POINT}"
if [[ -z "${DATA_MOUNT_POINT:-}" ]]; then
  echo "Warning: '${DATA_DISK_HOME_NAME}' mountpoint not detected; falling back to /Volumes/${DATA_DISK_HOME_NAME}."
  DATA_MOUNT_POINT="/Volumes/${DATA_DISK_HOME_NAME}"
  sudo mkdir -p "${DATA_MOUNT_POINT}"
fi

DATA_EFFECTIVE_USERS_ROOT="${DATA_MOUNT_POINT}/Users"
DATA_EFFECTIVE_SYSTEM_ROOT="${DATA_MOUNT_POINT}/system"
PRIMARY_USER_SUBVOLUME_MOUNT_POINT=""

DATA_CONTAINER_REF="$(diskutil info -plist "${DATA_DISK_HOME_NAME}" | plutil -extract APFSContainerReference raw -o - - 2>/dev/null || true)"
if [[ -z "${DATA_CONTAINER_REF:-}" ]]; then
  DATA_CONTAINER_REF="$(diskutil info "${DATA_DISK_HOME_NAME}" | awk -F': *' '/APFS Container Reference/ {print $2; exit}' || true)"
fi

if [[ -n "${DATA_CONTAINER_REF:-}" ]]; then
  PRIMARY_USER_COMPONENT="$(sanitize_volume_component "${DATA_HOME_USER}")"
  PRIMARY_USER_VOLUME_NAME="${DATA_HOME_VOLUME_PREFIX}-${DATA_HOME_USERS_SUBVOLUME_PREFIX}-${PRIMARY_USER_COMPONENT}"
  PRIMARY_USER_SUBVOLUME_MOUNT_POINT="$(ensure_apfs_volume "${DATA_CONTAINER_REF}" "${PRIMARY_USER_VOLUME_NAME}")"
  sudo mkdir -p "${PRIMARY_USER_SUBVOLUME_MOUNT_POINT}/Users"

  SYSTEM_VOLUME_NAME="${DATA_HOME_VOLUME_PREFIX} ${DATA_HOME_SYSTEM_SUBVOLUME_NAME}"
  SYSTEM_SUBVOLUME_MOUNT_POINT="$(ensure_apfs_volume "${DATA_CONTAINER_REF}" "${SYSTEM_VOLUME_NAME}")"
  sudo mkdir -p "${SYSTEM_SUBVOLUME_MOUNT_POINT}/system"

  DATA_EFFECTIVE_USERS_ROOT="${PRIMARY_USER_SUBVOLUME_MOUNT_POINT}/Users"
  DATA_EFFECTIVE_SYSTEM_ROOT="${SYSTEM_SUBVOLUME_MOUNT_POINT}/system"
  echo "Configured Data same-container APFS subvolumes:"
  echo "  users root:  ${DATA_EFFECTIVE_USERS_ROOT}"
  echo "  system root: ${DATA_EFFECTIVE_SYSTEM_ROOT}"
else
  echo "Warning: failed to resolve APFS container for ${DATA_DISK_HOME_NAME}; using root data volume paths."
fi

: "Relocate /Users to data volume"
USERS_RELOCATED=0
DATA_HOME_USER="$(resolve_data_home_user)"
ACTUAL_HOME_DIR="$(resolve_home_dir_for_user "${DATA_HOME_USER}")"
if [[ "${DATA_DEFER_USERS_CUTOVER}" == "1" ]]; then
  echo "Info: deferring live /Users cutover because DATA_DEFER_USERS_CUTOVER=${DATA_DEFER_USERS_CUTOVER}."
  echo "      Re-run with DATA_DEFER_USERS_CUTOVER=0 to attempt in-build /Users symlink cutover."
else
  if [[ ! -L /Users ]]; then
    USERS_TMP_PATH="/private/var/Users.migrate-tmp"
    sudo mkdir -p "${DATA_EFFECTIVE_USERS_ROOT}"
    if ! sudo ditto /Users "${DATA_EFFECTIVE_USERS_ROOT}"; then
      echo "Warning: ditto could not copy all files from /Users (likely protected container metadata)."
      echo "Retrying best-effort copy with rsync and known metadata exclusions..."
      if command -v rsync >/dev/null 2>&1; then
        sudo rsync -a --ignore-errors \
          --exclude='*/.com.apple.containermanagerd.metadata.plist' \
          /Users/ "${DATA_EFFECTIVE_USERS_ROOT}/" || true
      fi
    fi

    # On some macOS layouts, replacing /Users from a running system is not permitted.
    if sudo rm -rf "${USERS_TMP_PATH}" >/dev/null 2>&1 && sudo mv /Users "${USERS_TMP_PATH}" 2>/dev/null; then
      if sudo ln -s "${DATA_EFFECTIVE_USERS_ROOT}" /Users; then
        USERS_RELOCATED=1
        sudo rm -rf "${USERS_TMP_PATH}" >/dev/null 2>&1 || true
      else
        echo "Warning: failed to create /Users symlink; restoring original /Users."
        sudo mv "${USERS_TMP_PATH}" /Users || true
      fi
    else
      echo "Warning: unable to move /Users (likely read-only/protected root path). Skipping /Users symlink cutover."
    fi
  fi
fi

: "Fallback: copy full user home to data volume"
if [[ "${USERS_RELOCATED}" -eq 0 ]]; then
  USER_HOME="${ACTUAL_HOME_DIR}"
  DATA_USER_HOME="${DATA_EFFECTIVE_USERS_ROOT}/${DATA_HOME_USER}"

  if [[ -d "${USER_HOME}" ]]; then
    sudo mkdir -p "${DATA_USER_HOME}"

    if ! sudo ditto "${USER_HOME}" "${DATA_USER_HOME}"; then
      echo "Warning: ditto could not copy full ${USER_HOME}; trying rsync best-effort."
      if command -v rsync >/dev/null 2>&1; then
        sudo rsync -a --ignore-errors \
          --exclude='*/.com.apple.containermanagerd.metadata.plist' \
          "${USER_HOME}/" "${DATA_USER_HOME}/" || true
      fi
    fi

    echo "Home copy complete (fallback mode): ${USER_HOME} -> ${DATA_USER_HOME}"
    if [[ "${DATA_SET_PRIMARY_HOME_ON_DATA_VOLUME}" == "1" ]]; then
      echo "Info: account home mapping is configured automatically to the dedicated volume (NFSHomeDirectory)."
      echo "      Verify after reboot with: dscl . -read /Users/${DATA_HOME_USER} NFSHomeDirectory && echo \"\$HOME\""
    else
      echo "NOTE: Automatic account-home mapping is disabled (DATA_SET_PRIMARY_HOME_ON_DATA_VOLUME=${DATA_SET_PRIMARY_HOME_ON_DATA_VOLUME})."
      echo "      To switch account home manually: sudo dscl . -create /Users/${DATA_HOME_USER} NFSHomeDirectory '${DATA_USER_HOME}'"
      echo "      Verify after reboot with: dscl . -read /Users/${DATA_HOME_USER} NFSHomeDirectory && echo \"\$HOME\""
    fi
  else
    echo "Warning: user home ${USER_HOME} not found; skipping sub-level relocation."
  fi
fi

if [[ "${DATA_SET_PRIMARY_HOME_ON_DATA_VOLUME}" == "1" ]]; then
  PRIMARY_RECORD_PATH="/Users/${DATA_HOME_USER}"
  DESIRED_HOME="${DATA_EFFECTIVE_USERS_ROOT}/${DATA_HOME_USER}"

  if dscl . -read "${PRIMARY_RECORD_PATH}" >/dev/null 2>&1; then
    CURRENT_HOME="$(dscl . -read "${PRIMARY_RECORD_PATH}" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"

    sudo mkdir -p "${DESIRED_HOME}"
    sudo chown -R "${DATA_HOME_USER}:staff" "${DESIRED_HOME}" >/dev/null 2>&1 || true

    if [[ "${CURRENT_HOME}" != "${DESIRED_HOME}" ]]; then
      echo "Configuring ${DATA_HOME_USER} home on dedicated volume: ${DESIRED_HOME}"
      sudo dscl . -create "${PRIMARY_RECORD_PATH}" NFSHomeDirectory "${DESIRED_HOME}" || true
    else
      echo "Primary home already mapped to dedicated volume: ${DESIRED_HOME}"
    fi
    echo "Info: first-login home target is now '${DESIRED_HOME}' (subject to reboot/session refresh)."
  else
    echo "Warning: primary record ${PRIMARY_RECORD_PATH} missing; skipping NFSHomeDirectory mapping to dedicated volume."
  fi
fi

: "Relocate /private/var/lib to data volume"
if [[ "${DATA_DEFER_VAR_LIB_CUTOVER}" == "1" ]]; then
  echo "Info: deferring /private/var/lib cutover because DATA_DEFER_VAR_LIB_CUTOVER=${DATA_DEFER_VAR_LIB_CUTOVER}."
  echo "      Re-run with DATA_DEFER_VAR_LIB_CUTOVER=0 to attempt in-build /private/var/lib symlink cutover."
else
  if [[ -d /private/var/lib && ! -L /private/var/lib ]]; then
    sudo mkdir -p "${DATA_EFFECTIVE_SYSTEM_ROOT}/var-lib"
    sudo ditto /private/var/lib "${DATA_EFFECTIVE_SYSTEM_ROOT}/var-lib"
    sudo mv /private/var/lib /private/var/lib.local
    sudo ln -s "${DATA_EFFECTIVE_SYSTEM_ROOT}/var-lib" /private/var/lib
  fi

  : "Ensure /private/var/lib link exists"
  if [[ ! -e /private/var/lib ]]; then
    sudo mkdir -p "${DATA_EFFECTIVE_SYSTEM_ROOT}/var-lib"
    sudo ln -s "${DATA_EFFECTIVE_SYSTEM_ROOT}/var-lib" /private/var/lib
  fi
fi

: "Prepare dedicated role data copies (best-effort)"
if [[ -n "${USER_LIBRARY_MOUNT_POINT:-}" && "${DATA_COPY_USER_LIBRARY}" == "1" ]]; then
  SRC_LIBRARY="${ACTUAL_HOME_DIR}/Library"
  DST_LIBRARY="${USER_LIBRARY_MOUNT_POINT}/Users/${DATA_HOME_USER}/Library"
  if [[ -d "${SRC_LIBRARY}" ]]; then
    sudo mkdir -p "${DST_LIBRARY}"
    sudo ditto "${SRC_LIBRARY}" "${DST_LIBRARY}" || true
    echo "User Library copy complete (best-effort): ${SRC_LIBRARY} -> ${DST_LIBRARY}"
    echo "NOTE: To use dedicated user-library disk, switch NFSHomeDirectory to this disk path after reboot workflow."
  fi
fi

if [[ "${DATA_COPY_GIT_STORE}" == "1" ]]; then
  if [[ -n "${GIT_BARE_STORE_MOUNT_POINT:-}" ]]; then
    SRC_GIT_BARE_STORE="/private/var/lib/git/bare"
    DST_GIT_BARE_STORE="${GIT_BARE_STORE_MOUNT_POINT}/bare"
    if [[ -d "${SRC_GIT_BARE_STORE}" ]]; then
      sudo mkdir -p "${DST_GIT_BARE_STORE}"
      sudo ditto "${SRC_GIT_BARE_STORE}" "${DST_GIT_BARE_STORE}" || true
      echo "Git bare store copy complete (best-effort): ${SRC_GIT_BARE_STORE} -> ${DST_GIT_BARE_STORE}"
    fi
  fi

  if [[ -n "${GIT_STORE_DATA_MOUNT_POINT:-}" ]]; then
    SRC_GIT_WORKTREE_STORE="/private/var/lib/git/worktrees"
    DST_GIT_WORKTREE_STORE="${GIT_STORE_DATA_MOUNT_POINT}/worktrees"
    if [[ -d "${SRC_GIT_WORKTREE_STORE}" ]]; then
      sudo mkdir -p "${DST_GIT_WORKTREE_STORE}"
      sudo ditto "${SRC_GIT_WORKTREE_STORE}" "${DST_GIT_WORKTREE_STORE}" || true
      echo "Git worktree store copy complete (best-effort): ${SRC_GIT_WORKTREE_STORE} -> ${DST_GIT_WORKTREE_STORE}"
    fi

    for LEGACY_GIT_STORE_SRC in "/private/var/lib/git/Git Store" "${ACTUAL_HOME_DIR}/Git Store"; do
      if [[ -d "${LEGACY_GIT_STORE_SRC}" ]]; then
        LEGACY_GIT_STORE_DST="${GIT_STORE_DATA_MOUNT_POINT}/Git Store"
        sudo mkdir -p "${LEGACY_GIT_STORE_DST}"
        sudo ditto "${LEGACY_GIT_STORE_SRC}" "${LEGACY_GIT_STORE_DST}" || true
        echo "Legacy Git Store copy complete (best-effort): ${LEGACY_GIT_STORE_SRC} -> ${LEGACY_GIT_STORE_DST}"
      fi
    done
  fi
fi

if [[ "${GIT_STORE_CONFIGURE_SYSTEM_MOUNT}" == "1" ]]; then
  if [[ -n "${GIT_BARE_STORE_MOUNT_POINT:-}" && -n "${GIT_STORE_DATA_MOUNT_POINT:-}" ]]; then
    GIT_WORKTREE_CANONICAL_ROOT="${GIT_STORE_DATA_MOUNT_POINT}/worktrees"
    GIT_BARE_CANONICAL_ROOT="${GIT_BARE_STORE_MOUNT_POINT}/bare"
    sudo mkdir -p "${GIT_WORKTREE_CANONICAL_ROOT}" "${GIT_BARE_CANONICAL_ROOT}"

    # Migrate legacy root content into worktree canonical root when present.
    if [[ -d "${GIT_STORE_SYSTEM_MOUNT_POINT}" && ! -L "${GIT_STORE_SYSTEM_MOUNT_POINT}" ]]; then
      sudo ditto "${GIT_STORE_SYSTEM_MOUNT_POINT}" "${GIT_WORKTREE_CANONICAL_ROOT}" || true
      sudo rm -rf "${GIT_STORE_SYSTEM_MOUNT_POINT}"
    fi

    # Maintain compatibility with old split layout source paths, but normalize to .bare model.
    if [[ -d "${GIT_STORE_SYSTEM_MOUNT_POINT}/bare" && ! -L "${GIT_STORE_SYSTEM_MOUNT_POINT}/bare" ]]; then
      sudo ditto "${GIT_STORE_SYSTEM_MOUNT_POINT}/bare" "${GIT_BARE_CANONICAL_ROOT}" || true
      sudo rm -rf "${GIT_STORE_SYSTEM_MOUNT_POINT}/bare"
    fi
    if [[ -d "${GIT_STORE_SYSTEM_MOUNT_POINT}/worktrees" && ! -L "${GIT_STORE_SYSTEM_MOUNT_POINT}/worktrees" ]]; then
      sudo ditto "${GIT_STORE_SYSTEM_MOUNT_POINT}/worktrees" "${GIT_WORKTREE_CANONICAL_ROOT}" || true
      sudo rm -rf "${GIT_STORE_SYSTEM_MOUNT_POINT}/worktrees"
    fi

    sudo ln -sfn "${GIT_WORKTREE_CANONICAL_ROOT}" "${GIT_STORE_SYSTEM_MOUNT_POINT}"

    if [[ -d "${GIT_WORKTREE_CANONICAL_ROOT}/.bare" && ! -L "${GIT_WORKTREE_CANONICAL_ROOT}/.bare" ]]; then
      sudo ditto "${GIT_WORKTREE_CANONICAL_ROOT}/.bare" "${GIT_BARE_CANONICAL_ROOT}" || true
      sudo rm -rf "${GIT_WORKTREE_CANONICAL_ROOT}/.bare"
    fi
    sudo ln -sfn "${GIT_BARE_CANONICAL_ROOT}" "${GIT_WORKTREE_CANONICAL_ROOT}/.bare"

    echo "Configured Git system mount roots via dedicated role disks:"
    echo "  ${GIT_STORE_SYSTEM_MOUNT_POINT} -> ${GIT_WORKTREE_CANONICAL_ROOT}"
    echo "  ${GIT_STORE_SYSTEM_MOUNT_POINT}/.bare -> ${GIT_BARE_CANONICAL_ROOT}"
  else
    echo "Warning: Git system mount wiring requested but Git Bare/Worktree role mountpoints were not both detected."
  fi
fi

if [[ -n "${NIX_STORE_MOUNT_POINT:-}" && "${DATA_COPY_NIX_STORE}" == "1" ]]; then
  SRC_NIX_STORE="/nix"
  DST_NIX_STORE="${NIX_STORE_MOUNT_POINT}/nix"
  if [[ -d "${SRC_NIX_STORE}" ]]; then
    sudo mkdir -p "${DST_NIX_STORE}"
    sudo rsync -a --ignore-errors "${SRC_NIX_STORE}/" "${DST_NIX_STORE}/" || true
    echo "Nix store copy complete (best-effort): ${SRC_NIX_STORE} -> ${DST_NIX_STORE}"
    echo "NOTE: Using dedicated Nix disk as live /nix requires additional nix-darwin/Nix setup."
  fi
fi

if [[ -n "${BUILD_CHAINS_MOUNT_POINT:-}" && "${DATA_COPY_BUILD_CHAINS}" == "1" ]]; then
  DEST_BASE="${BUILD_CHAINS_MOUNT_POINT}/Users/${DATA_HOME_USER}/build-chains-cache"
  sudo mkdir -p "${DEST_BASE}"

  for chain_dir in "go" ".m2" ".npm" ".cache"; do
    SRC_PATH="${ACTUAL_HOME_DIR}/${chain_dir}"
    DST_PATH="${DEST_BASE}/${chain_dir}"
    if [[ -d "${SRC_PATH}" ]]; then
      sudo mkdir -p "${DST_PATH}"
      sudo ditto "${SRC_PATH}" "${DST_PATH}" || true
      echo "Build chain copy complete (best-effort): ${SRC_PATH} -> ${DST_PATH}"
      echo "NOTE: switch ${SRC_PATH} to ${DST_PATH} via symlink after reboot validation if desired."
    fi
  done
fi

: "Sanity checks"
if [[ "${USERS_RELOCATED}" -eq 1 ]]; then
  test -L /Users
elif [[ "${DATA_DEFER_USERS_CUTOVER}" == "1" ]]; then
  echo "Info: /Users cutover intentionally deferred for this run."
else
  echo "Warning: /Users relocation was not applied on this run."
fi

if [[ "${DATA_DEFER_VAR_LIB_CUTOVER}" == "1" ]]; then
  if [[ -L /private/var/lib ]]; then
    echo "Info: /private/var/lib is already symlinked from a previous run."
  else
    echo "Info: /private/var/lib cutover intentionally deferred for this run."
  fi
else
  test -L /private/var/lib
fi
