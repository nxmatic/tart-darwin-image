#!/usr/bin/env bash
set -euo pipefail

for img in .tart/disks/nikopol/git-bare-store.asif .tart/disks/nikopol/git-worktree-store.asif; do
  echo "=== ${img} ==="
  if ! json="$(diskutil image attach -nomount -nobrowse -plist "$img" | plutil -convert json -o - -- -)"; then
    echo "attach_failed"
    continue
  fi

  vols="$(printf '%s\n' "$json" | yq -p json -r '."system-entities"[] | select((."filesystem-type"=="apfs") or (."content-hint"=="Apple_APFS_Volume")) | ."dev-entry"')"
  if [[ -z "$vols" ]]; then
    echo "no_apfs_volumes"
  fi

  while IFS= read -r v; do
    [[ -z "$v" ]] && continue
    dev="/dev/${v#/dev/}"
    info="$(diskutil info -plist "$dev" | plutil -convert json -o - -- -)"
    name="$(printf '%s\n' "$info" | yq -p json -r '.VolumeName // ""')"
    locked="$(printf '%s\n' "$info" | yq -p json -r '.Locked // false')"
    owners="$(printf '%s\n' "$info" | yq -p json -r '.GlobalPermissionsEnabled // "unknown"')"
    mp="$(printf '%s\n' "$info" | yq -p json -r '.MountPoint // ""')"
    echo "${dev} | name=${name} | locked=${locked} | owners=${owners} | mount=${mp}"
  done <<< "$vols"

  base="$(printf '%s\n' "$json" | yq -p json -r '."system-entities"[] | ."dev-entry" | select(test("^(/dev/)?disk[0-9]+$"))' | awk 'NR==1{print}')"
  if [[ -n "$base" ]]; then
    diskutil image detach "/dev/${base#/dev/}" >/dev/null 2>&1 || true
  fi

done
