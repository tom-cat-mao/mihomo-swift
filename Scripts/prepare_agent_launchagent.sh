#!/usr/bin/env bash
#
# Renders the bundled user-agent LaunchAgent plist for Kumo.app.
#
# Kumo.app ships the user tier ("kumod") as the shared KumoService binary plus
# a static LaunchAgent plist at
# Contents/Library/LaunchAgents/io.kumo.KumoAgent.plist, which is where
# SMAppService.agent(plistName:) requires it. launchd needs absolute paths for
# the helper, the app-support directory and the launchd-owned socket, so this
# script renders them from the checked-in template. Keep the rendered key set
# in sync with KumoUserAgentManager.launchAgentPlist(...), which produces the
# equivalent plist at runtime for source-tree and dev installations.
#
# Required:
#   KUMO_HELPER_PATH          Absolute path of the bundled KumoService helper.
#   KUMO_AGENT_PLIST_OUTPUT   Destination plist path (created if needed).
#
# Optional (defaults match KumoPaths):
#   KUMO_AGENT_PLIST_TEMPLATE   Default: Resources/KumoApp/LaunchAgents/io.kumo.KumoAgent.plist
#   KUMO_APP_SUPPORT_DIR        Default: $HOME/Library/Application Support/Kumo
#   KUMO_AGENT_SOCKET_PATH      Default: $KUMO_APP_SUPPORT_DIR/kumo-agent.sock
#   KUMO_AGENT_LOG_PATH         Default: $KUMO_APP_SUPPORT_DIR/logs/agent.log
#   KUMO_AGENT_IDLE_TIMEOUT     Default: 300 (ServiceIdlePolicy.defaultTimeoutSeconds)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

TEMPLATE_PATH="${KUMO_AGENT_PLIST_TEMPLATE:-${REPO_ROOT}/Resources/KumoApp/LaunchAgents/io.kumo.KumoAgent.plist}"
OUTPUT_PATH="${KUMO_AGENT_PLIST_OUTPUT:-}"
HELPER_PATH="${KUMO_HELPER_PATH:-}"
APP_SUPPORT_DIR="${KUMO_APP_SUPPORT_DIR:-${HOME}/Library/Application Support/Kumo}"
SOCKET_PATH="${KUMO_AGENT_SOCKET_PATH:-${APP_SUPPORT_DIR}/kumo-agent.sock}"
LOG_PATH="${KUMO_AGENT_LOG_PATH:-${APP_SUPPORT_DIR}/logs/agent.log}"
IDLE_TIMEOUT="${KUMO_AGENT_IDLE_TIMEOUT:-300}"

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

[[ -f "${TEMPLATE_PATH}" ]] || fail "template not found: ${TEMPLATE_PATH}"
[[ -n "${HELPER_PATH}" ]] || fail "KUMO_HELPER_PATH is required (absolute path of the bundled KumoService)"
[[ "${HELPER_PATH}" == /* ]] || fail "KUMO_HELPER_PATH must be absolute: ${HELPER_PATH}"
[[ -n "${OUTPUT_PATH}" ]] || fail "KUMO_AGENT_PLIST_OUTPUT is required"
[[ "${IDLE_TIMEOUT}" =~ ^[1-9][0-9]*$ ]] || fail "KUMO_AGENT_IDLE_TIMEOUT must be a positive integer: ${IDLE_TIMEOUT}"

for value in "${HELPER_PATH}" "${APP_SUPPORT_DIR}" "${SOCKET_PATH}" "${LOG_PATH}"; do
  case "${value}" in
    *'&'*|*'<'*|*'>'*|*$'\n'*)
      fail "path contains characters that are not safe in an XML plist: ${value}"
      ;;
  esac
done

escape_sed_replacement() {
  printf '%s' "$1" | sed 's/[&|\\]/\\&/g'
}

mkdir -p "$(dirname "${OUTPUT_PATH}")"

sed \
  -e "s|__KUMO_HELPER_PATH__|$(escape_sed_replacement "${HELPER_PATH}")|g" \
  -e "s|__KUMO_APP_SUPPORT_DIR__|$(escape_sed_replacement "${APP_SUPPORT_DIR}")|g" \
  -e "s|__KUMO_AGENT_SOCKET_PATH__|$(escape_sed_replacement "${SOCKET_PATH}")|g" \
  -e "s|__KUMO_AGENT_LOG_PATH__|$(escape_sed_replacement "${LOG_PATH}")|g" \
  -e "s|__KUMO_IDLE_TIMEOUT__|$(escape_sed_replacement "${IDLE_TIMEOUT}")|g" \
  "${TEMPLATE_PATH}" > "${OUTPUT_PATH}"

chmod 644 "${OUTPUT_PATH}"

if grep -q '__KUMO_' "${OUTPUT_PATH}"; then
  fail "unreplaced placeholder remains in ${OUTPUT_PATH}"
fi

/usr/bin/plutil -lint "${OUTPUT_PATH}" >/dev/null || fail "rendered plist failed plutil -lint: ${OUTPUT_PATH}"

if [[ ! -x "${HELPER_PATH}" ]]; then
  printf 'warning: KumoService not found at %s; bundle the helper before installing the agent\n' "${HELPER_PATH}" >&2
fi

printf 'Rendered %s\n' "${OUTPUT_PATH}"
