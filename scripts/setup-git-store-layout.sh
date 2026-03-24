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

: "${GIT_STORE_LAYOUT_MODE:=split}"
: "${GIT_STORE_BARE_ROOT:=/private/var/lib/git/.bare}"
: "${GIT_STORE_WORKTREE_ROOT:=/private/var/lib/git}"
: "${GIT_STORE_MIGRATE_EXISTING:=1}"
: "${GIT_STORE_PRIMARY_OWNER:=${DATA_HOME_USER:-${PRIMARY_ACCOUNT_NAME:-admin}}}"

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

normalize_rel_path() {
  local value="$1"
  value="${value#./}"
  value="${value#/}"
  printf '%s\n' "${value}"
}

relative_path_from_root() {
  local path="$1"
  local root="$2"

  if [[ "${path}" == "${root}" ]]; then
    printf '%s\n' "$(basename "${path}")"
    return 0
  fi

  if [[ "${path}" == "${root}"/* ]]; then
    printf '%s\n' "${path#"${root}/"}"
    return 0
  fi

  printf '%s\n' "$(basename "${path}")"
}

is_bare_repo() {
  local path="$1"
  [[ -d "${path}" ]] || return 1
  [[ -f "${path}/HEAD" ]] || return 1
  [[ -d "${path}/objects" ]] || return 1
  [[ -d "${path}/refs" ]] || return 1
  [[ ! -e "${path}/.git" ]]
}

is_worktree_repo() {
  local path="$1"
  [[ -d "${path}/.git" ]]
}

ensure_dir_owned() {
  local path="$1"
  sudo mkdir -p "${path}"
  sudo chown "${GIT_STORE_PRIMARY_OWNER}:staff" "${path}" >/dev/null 2>&1 || true
}

ensure_tree_owned() {
  local path="$1"
  if [[ -e "${path}" ]]; then
    sudo chown -R "${GIT_STORE_PRIMARY_OWNER}:staff" "${path}" >/dev/null 2>&1 || true
  fi
}

ensure_private_var_lib_root() {
  local lib_target=""
  local lib_target_abs=""

  sudo mkdir -p /private/var

  if [[ -L /private/var/lib ]]; then
    lib_target="$(readlink /private/var/lib || true)"
    if [[ -n "${lib_target}" ]]; then
      if [[ "${lib_target}" = /* ]]; then
        lib_target_abs="${lib_target}"
      else
        lib_target_abs="/private/var/${lib_target}"
      fi
      sudo mkdir -p "${lib_target_abs}"
      return 0
    fi
  fi

  if [[ ! -e /private/var/lib ]]; then
    sudo mkdir -p /private/var/lib
    return 0
  fi

  if [[ ! -d /private/var/lib ]]; then
    echo "Warning: /private/var/lib exists but is not a directory; recreating directory root."
    sudo rm -f /private/var/lib
    sudo mkdir -p /private/var/lib
  fi
}

migrate_worktree_repo() {
  local repo_path="$1"
  local source_root="$2"
  local rel_path bare_rel worktree_rel dest_bare dest_worktree

  rel_path="$(relative_path_from_root "${repo_path}" "${source_root}")"
  rel_path="$(normalize_rel_path "${rel_path}")"
  worktree_rel="${rel_path%.git}"
  bare_rel="${worktree_rel}.git"

  dest_bare="${GIT_STORE_BARE_ROOT}/${bare_rel}"
  dest_worktree="${GIT_STORE_WORKTREE_ROOT}/${worktree_rel}"

  if [[ "${repo_path}" == "${dest_worktree}" ]]; then
    return 0
  fi

  ensure_dir_owned "$(dirname "${dest_bare}")"
  ensure_dir_owned "$(dirname "${dest_worktree}")"

  if [[ ! -d "${dest_bare}" ]]; then
    git clone --bare "${repo_path}" "${dest_bare}"
  fi

  if [[ ! -d "${dest_worktree}" ]]; then
    git clone "${dest_bare}" "${dest_worktree}"
  fi

  ensure_tree_owned "${dest_bare}"
  ensure_tree_owned "${dest_worktree}"
}

migrate_bare_repo() {
  local repo_path="$1"
  local source_root="$2"
  local rel_path bare_rel worktree_rel dest_bare dest_worktree

  rel_path="$(relative_path_from_root "${repo_path}" "${source_root}")"
  rel_path="$(normalize_rel_path "${rel_path}")"

  if [[ "${rel_path}" == *.git ]]; then
    bare_rel="${rel_path}"
    worktree_rel="${rel_path%.git}"
  else
    bare_rel="${rel_path}.git"
    worktree_rel="${rel_path}"
  fi

  dest_bare="${GIT_STORE_BARE_ROOT}/${bare_rel}"
  dest_worktree="${GIT_STORE_WORKTREE_ROOT}/${worktree_rel}"

  if [[ "${repo_path}" == "${dest_bare}" ]]; then
    if [[ ! -d "${dest_worktree}" ]]; then
      ensure_dir_owned "$(dirname "${dest_worktree}")"
      git clone "${dest_bare}" "${dest_worktree}"
      ensure_tree_owned "${dest_worktree}"
    fi
    return 0
  fi

  ensure_dir_owned "$(dirname "${dest_bare}")"
  ensure_dir_owned "$(dirname "${dest_worktree}")"

  if [[ ! -d "${dest_bare}" ]]; then
    git clone --mirror "${repo_path}" "${dest_bare}"
  fi

  if [[ ! -d "${dest_worktree}" ]]; then
    git clone "${dest_bare}" "${dest_worktree}"
  fi

  ensure_tree_owned "${dest_bare}"
  ensure_tree_owned "${dest_worktree}"
}

is_under_new_layout() {
  local path="$1"
  [[ "${path}" == "${GIT_STORE_BARE_ROOT}" || "${path}" == "${GIT_STORE_BARE_ROOT}"/* || "${path}" == "${GIT_STORE_WORKTREE_ROOT}" || "${path}" == "${GIT_STORE_WORKTREE_ROOT}"/* ]]
}

main() {
  local primary_home source_root
  local -a source_roots

  if [[ "${GIT_STORE_LAYOUT_MODE}" != "split" ]]; then
    echo "Skipping Git store split layout setup (GIT_STORE_LAYOUT_MODE=${GIT_STORE_LAYOUT_MODE})."
    exit 0
  fi

  if [[ "${GIT_STORE_MIGRATE_EXISTING}" != "1" ]]; then
    echo "Skipping Git store migration (GIT_STORE_MIGRATE_EXISTING=${GIT_STORE_MIGRATE_EXISTING})."
    exit 0
  fi

  if ! command -v git >/dev/null 2>&1; then
    echo "Error: git command not found; cannot migrate repositories." >&2
    exit 1
  fi

  primary_home="$(resolve_home_dir_for_user "${GIT_STORE_PRIMARY_OWNER}")"

  ensure_private_var_lib_root
  ensure_dir_owned "${GIT_STORE_BARE_ROOT}"
  ensure_dir_owned "${GIT_STORE_WORKTREE_ROOT}"

  source_roots=(
    "/private/var/lib/git/.bare"
    "/private/var/lib/git"
    "/private/var/lib/git/worktrees"
    "/private/var/lib/git/bare"
    "/private/var/lib/git/Git Store"
    "${primary_home}/Git Store"
  )

  for source_root in "${source_roots[@]}"; do
    [[ -d "${source_root}" ]] || continue

    while IFS= read -r gitdir; do
      repo_path="${gitdir%/.git}"
      [[ -d "${repo_path}" ]] || continue
      is_under_new_layout "${repo_path}" && continue
      if is_worktree_repo "${repo_path}"; then
        migrate_worktree_repo "${repo_path}" "${source_root}"
      fi
    done < <(find "${source_root}" -type d -name .git 2>/dev/null)

    while IFS= read -r candidate; do
      [[ -d "${candidate}" ]] || continue
      [[ "${candidate}" == */.git ]] && continue
      is_under_new_layout "${candidate}" && continue
      if is_bare_repo "${candidate}"; then
        migrate_bare_repo "${candidate}" "${source_root}"
      fi
    done < <(find "${source_root}" -type d -name '*.git' 2>/dev/null)

    if is_bare_repo "${source_root}" && ! is_under_new_layout "${source_root}"; then
      migrate_bare_repo "${source_root}" "$(dirname "${source_root}")"
    fi
  done

  ensure_tree_owned "${GIT_STORE_BARE_ROOT}"
  ensure_tree_owned "${GIT_STORE_WORKTREE_ROOT}"

  echo "Git store split layout ready:"
  echo "  bare: ${GIT_STORE_BARE_ROOT}"
  echo "  worktrees: ${GIT_STORE_WORKTREE_ROOT}"
}

main "$@"
