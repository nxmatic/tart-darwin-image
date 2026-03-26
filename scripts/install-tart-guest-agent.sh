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

: "Create temporary workspace"
TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "${TMP_DIR}"; }
trap cleanup EXIT

: "Resolve latest Darwin guest-agent release asset"
ASSET_URL=""
for REPO in cirruslabs/tart-guest-agent cirruslabs/tart; do
  JSON="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" || true)"
  if [[ -z "${JSON}" ]]; then
    continue
  fi

  CANDIDATE_PRIMARY="$({
    printf '%s\n' "${JSON}" \
      | grep -E '"browser_download_url"' \
      | grep -E 'darwin' \
      | grep -E '(arm64|aarch64|universal)' \
      | grep -E '\.tar\.gz"' \
      | head -n 1 \
      | sed -E 's/^[[:space:]]*"browser_download_url"[[:space:]]*:[[:space:]]*"([^"]+)".*$/\1/'
  } || true)"

  CANDIDATE_FALLBACK="$({
    printf '%s\n' "${JSON}" \
      | grep -E '"browser_download_url"' \
      | grep -E 'darwin' \
      | grep -E '\.tar\.gz"' \
      | head -n 1 \
      | sed -E 's/^[[:space:]]*"browser_download_url"[[:space:]]*:[[:space:]]*"([^"]+)".*$/\1/'
  } || true)"

  CANDIDATE="${CANDIDATE_PRIMARY:-${CANDIDATE_FALLBACK}}"
  if [[ -n "${CANDIDATE}" ]]; then
    ASSET_URL="${CANDIDATE}"
    break
  fi
done

: "Fail fast if no matching release asset found"
if [[ -z "${ASSET_URL}" ]]; then
  echo 'Failed to locate a Darwin tart-guest-agent tarball in latest GitHub releases.' >&2
  exit 1
fi

echo "Selected tart-guest-agent asset URL: ${ASSET_URL}"

: "Download and unpack guest-agent tarball"
curl -fL "${ASSET_URL}" -o "${TMP_DIR}/tart-guest-agent.tar.gz"
tar -xzf "${TMP_DIR}/tart-guest-agent.tar.gz" -C "${TMP_DIR}"

: "Locate unpacked tart-guest-agent binary"
BIN_PATH="$(find "${TMP_DIR}" -type f -name tart-guest-agent | head -n 1 || true)"
if [[ -z "${BIN_PATH}" ]]; then
  echo 'tart-guest-agent binary not found in downloaded archive.' >&2
  exit 1
fi

: "Install binary into /opt/tart/bin"
sudo install -d -m 0755 /opt/tart/bin
sudo install -m 0755 "${BIN_PATH}" /opt/tart/bin/tart-guest-agent
test -x /opt/tart/bin/tart-guest-agent

: "Install split launchd services: RPC and clipboard"
RPC_LABEL="org.cirruslabs.tart-guest-rpc"
CLIPBOARD_LABEL="org.cirruslabs.tart-guest-clipboard"
RPC_DAEMON_PATH="/Library/LaunchDaemons/${RPC_LABEL}.plist"
CLIPBOARD_AGENT_PATH="/Library/LaunchAgents/${CLIPBOARD_LABEL}.plist"
TART_AGENT_USER="${TART_GUEST_AGENT_USER:-${AUTO_LOGIN_USER:-admin}}"
TART_AGENT_UID="$(id -u "${TART_AGENT_USER}" 2>/dev/null || true)"
TART_AGENT_HOME="$(dscl . -read "/Users/${TART_AGENT_USER}" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
if [[ -z "${TART_AGENT_HOME}" ]]; then
  TART_AGENT_HOME="/Users/${TART_AGENT_USER}"
fi

RUNTIME_PATH_VALUE="/opt/tart/bin:/run/wrappers/bin:/run/current-system/sw/bin:/bin:/usr/bin:/usr/sbin:/usr/local/bin"
RPC_LOG_PATH="/var/log/tart-guest-rpc.log"
CLIPBOARD_LOG_PATH="/var/log/tart-guest-clipboard.log"

: "Prepare log files in /var/log"
sudo install -d -m 0755 /var/log
sudo touch "${RPC_LOG_PATH}" "${CLIPBOARD_LOG_PATH}"
sudo chown root:wheel "${RPC_LOG_PATH}"
sudo chmod 0644 "${RPC_LOG_PATH}"
if [[ -n "${TART_AGENT_UID}" ]]; then
  sudo chown "${TART_AGENT_USER}":staff "${CLIPBOARD_LOG_PATH}" || true
else
  sudo chown root:wheel "${CLIPBOARD_LOG_PATH}"
fi
sudo chmod 0644 "${CLIPBOARD_LOG_PATH}"

: "Generate RPC launch daemon plist"
cat > "${TMP_DIR}/tart-guest-rpc.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key>
    <string>${RPC_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
      <string>/opt/tart/bin/tart-guest-agent</string>
      <string>--run-rpc</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
      <key>PATH</key>
      <string>${RUNTIME_PATH_VALUE}</string>
    </dict>
    <key>WorkingDirectory</key>
    <string>/var/empty</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${RPC_LOG_PATH}</string>
    <key>StandardErrorPath</key>
    <string>${RPC_LOG_PATH}</string>
  </dict>
</plist>
EOF

: "Generate clipboard launch agent plist"
cat > "${TMP_DIR}/tart-guest-clipboard.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key>
    <string>${CLIPBOARD_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
      <string>/opt/tart/bin/tart-guest-agent</string>
      <string>--run-vdagent</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
      <key>PATH</key>
      <string>${RUNTIME_PATH_VALUE}</string>
      <key>TERM</key>
      <string>xterm-256color</string>
    </dict>
    <key>WorkingDirectory</key>
    <string>${TART_AGENT_HOME}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${CLIPBOARD_LOG_PATH}</string>
    <key>StandardErrorPath</key>
    <string>${CLIPBOARD_LOG_PATH}</string>
  </dict>
</plist>
EOF

: "Install system daemon and global agent plists"
sudo install -d -m 0755 /Library/LaunchDaemons /Library/LaunchAgents
sudo install -m 0644 "${TMP_DIR}/tart-guest-rpc.plist" "${RPC_DAEMON_PATH}"
sudo install -m 0644 "${TMP_DIR}/tart-guest-clipboard.plist" "${CLIPBOARD_AGENT_PATH}"
sudo chown root:wheel "${RPC_DAEMON_PATH}" "${CLIPBOARD_AGENT_PATH}"

: "Validate plist syntax"
sudo plutil -lint "${RPC_DAEMON_PATH}"
sudo plutil -lint "${CLIPBOARD_AGENT_PATH}"

: "Restart RPC service in system domain"
sudo launchctl bootout "system/${RPC_LABEL}" >/dev/null 2>&1 || true
sudo launchctl bootstrap system "${RPC_DAEMON_PATH}"
sudo launchctl enable "system/${RPC_LABEL}" || true
sudo launchctl kickstart -k "system/${RPC_LABEL}" || true

: "Restart clipboard service in GUI domain when user domain is available"
if [[ -n "${TART_AGENT_UID}" ]]; then
  sudo launchctl bootout "gui/${TART_AGENT_UID}/${CLIPBOARD_LABEL}" >/dev/null 2>&1 || true
  sudo launchctl bootstrap "gui/${TART_AGENT_UID}" "${CLIPBOARD_AGENT_PATH}" || true
  sudo launchctl enable "gui/${TART_AGENT_UID}/${CLIPBOARD_LABEL}" || true
  sudo launchctl kickstart -k "gui/${TART_AGENT_UID}/${CLIPBOARD_LABEL}" || true
else
  echo "WARNING: Could not resolve UID for ${TART_AGENT_USER}; installed ${CLIPBOARD_AGENT_PATH} but skipped runtime bootstrap."
fi

: "Best-effort cleanup of legacy single-service guest-agent units"
for legacy_label in org.cirruslabs.tart-guest-agent org.cirruslabs.tart-guest-daemon; do
  sudo launchctl bootout "system/${legacy_label}" >/dev/null 2>&1 || true
done

for legacy_plist in \
  /Library/LaunchDaemons/org.cirruslabs.tart-guest-agent.plist \
  /Library/LaunchDaemons/org.cirruslabs.tart-guest-daemon.plist \
  /Library/LaunchAgents/org.cirruslabs.tart-guest-agent.plist; do
  if [[ -f "${legacy_plist}" ]]; then
    sudo rm -f "${legacy_plist}"
  fi
done

for user_home in /Users/*; do
  [[ -d "${user_home}/Library/LaunchAgents" ]] || continue
  if [[ -f "${user_home}/Library/LaunchAgents/org.cirruslabs.tart-guest-agent.plist" ]]; then
    sudo rm -f "${user_home}/Library/LaunchAgents/org.cirruslabs.tart-guest-agent.plist"
  fi
done
