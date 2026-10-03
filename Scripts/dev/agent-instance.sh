#!/usr/bin/env bash
#
# Manage a fully isolated dev instance of the user-level Kumo agent tier
# ("kumod") on this host.
#
# The instance runs under a disjoint launchd label, application-support root,
# plist and socket, so it can never touch the production Kumo install
# (~/Library/Application Support/Kumo, io.kumo.KumoAgent). The script refuses
# production paths and labels even when the caller overrides the defaults.
#
# Usage:
#   Scripts/dev/agent-instance.sh install      # build if stale, install + load
#   Scripts/dev/agent-instance.sh status       # signed status (starts on demand)
#   Scripts/dev/agent-instance.sh logs [-f]    # tail the dev agent log
#   Scripts/dev/agent-instance.sh uninstall    # bootout + remove plist/socket
#
# Environment:
#   KUMO_APP_SUPPORT_DIR   default: ~/Library/Application Support/KumoDev
#   KUMO_AGENT_LABEL       default: io.kumo.KumoAgent.dev
#   KUMO_DEV_IDLE_TIMEOUT  idle-exit seconds baked into the plist (default 300)
#   KUMO_DEV_SERVICE_BIN   KumoService binary (default .build/debug/KumoService)
#   KUMO_DEV_SKIP_BUILD=1  reuse the existing binary instead of rebuilding
#
# See docs/quality/testing-quality.md (L1 layer) for the hermetic smoke test.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SERVICE_BIN="${KUMO_DEV_SERVICE_BIN:-${REPO_ROOT}/.build/debug/KumoService}"

PRODUCTION_APP_SUPPORT="${HOME}/Library/Application Support/Kumo"
PRODUCTION_AGENT_LABEL="io.kumo.KumoAgent"

export KUMO_APP_SUPPORT_DIR="${KUMO_APP_SUPPORT_DIR:-${HOME}/Library/Application Support/KumoDev}"
export KUMO_AGENT_LABEL="${KUMO_AGENT_LABEL:-io.kumo.KumoAgent.dev}"

usage() {
  sed -n '3,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

fatal() {
  echo "error: $*" >&2
  exit 1
}

realpath_dir() {
  python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

require_dev_isolation() {
  local support label
  support="$(realpath_dir "${KUMO_APP_SUPPORT_DIR}")"
  label="${KUMO_AGENT_LABEL}"

  if [[ -z "${support}" || "${support}" != /* ]]; then
    fatal "KUMO_APP_SUPPORT_DIR must be an absolute path."
  fi
  if [[ "${support}" == "$(realpath_dir "${PRODUCTION_APP_SUPPORT}")" ]]; then
    fatal "KUMO_APP_SUPPORT_DIR resolves to the production app-support root; refusing."
  fi
  if [[ "${label}" == "${PRODUCTION_AGENT_LABEL}" ]]; then
    fatal "KUMO_AGENT_LABEL is the production launchd label; refusing (it would bootout the production agent)."
  fi
  if [[ ! "${label}" =~ ^[A-Za-z0-9._-]+$ ]]; then
    fatal "KUMO_AGENT_LABEL '${label}' is not a valid launchd label."
  fi
}

plist_path() {
  printf '%s\n' "${HOME}/Library/LaunchAgents/${KUMO_AGENT_LABEL}.plist"
}

socket_path() {
  printf '%s\n' "${KUMO_APP_SUPPORT_DIR}/kumo-agent.sock"
}

job_is_registered() {
  launchctl print "gui/${UID}/${KUMO_AGENT_LABEL}" >/dev/null 2>&1
}

ensure_service_binary() {
  if [[ "${KUMO_DEV_SKIP_BUILD:-0}" == "1" && -x "${SERVICE_BIN}" ]]; then
    return
  fi
  echo "building KumoService (KUMO_CLT_BUILD=${KUMO_CLT_BUILD-1})..."
  (
    cd "${REPO_ROOT}"
    KUMO_CLT_BUILD="${KUMO_CLT_BUILD-1}" swift build --product KumoService
  )
  [[ -x "${SERVICE_BIN}" ]] || fatal "KumoService binary not found at ${SERVICE_BIN} after build."
}

cmd_install() {
  require_dev_isolation
  ensure_service_binary
  "${SERVICE_BIN}" service install \
    --mode user \
    --source "${SERVICE_BIN}" \
    --app-support "${KUMO_APP_SUPPORT_DIR}" \
    --idle-timeout "${KUMO_DEV_IDLE_TIMEOUT:-300}"
  echo "installed ${KUMO_AGENT_LABEL}"
  echo "  plist:  $(plist_path)"
  echo "  socket: $(socket_path)"
  echo "  logs:   ${KUMO_APP_SUPPORT_DIR}/logs/agent.log"
}

cmd_status() {
  require_dev_isolation
  [[ -x "${SERVICE_BIN}" ]] || fatal "KumoService is not built; run 'agent-instance.sh install' first."
  "${SERVICE_BIN}" service status --mode user --app-support "${KUMO_APP_SUPPORT_DIR}"
}

cmd_logs() {
  require_dev_isolation
  local log_file="${KUMO_APP_SUPPORT_DIR}/logs/agent.log"
  [[ -f "${log_file}" ]] || fatal "No agent log yet at ${log_file}."
  if [[ "${1:-}" == "-f" || "${1:-}" == "--follow" ]]; then
    tail -f "${log_file}"
  else
    tail -n "${KUMO_DEV_LOG_LINES:-80}" "${log_file}"
  fi
}

cmd_uninstall() {
  require_dev_isolation
  # The trap guarantees the launchd job and files are gone even when the
  # manager call fails or the script is interrupted midway.
  trap cleanup_instance EXIT
  if ! "${SERVICE_BIN}" service uninstall --mode user --app-support "${KUMO_APP_SUPPORT_DIR}" >/dev/null 2>&1; then
    echo "warning: manager uninstall failed; forcing cleanup for ${KUMO_AGENT_LABEL}" >&2
  fi
  cleanup_instance
  if job_is_registered; then
    fatal "launchctl still reports gui/${UID}/${KUMO_AGENT_LABEL} after uninstall."
  fi
  if [[ -e "$(plist_path)" || -e "$(socket_path)" ]]; then
    fatal "Dev instance files are still present after uninstall."
  fi
  echo "uninstalled ${KUMO_AGENT_LABEL} (launchd job, plist and socket removed)"
}

cleanup_instance() {
  launchctl bootout "gui/${UID}/${KUMO_AGENT_LABEL}" >/dev/null 2>&1 || true
  rm -f "$(plist_path)" "$(socket_path)"
}

command="${1:-}"
shift || true

case "${command}" in
  install) cmd_install ;;
  status) cmd_status ;;
  logs) cmd_logs "$@" ;;
  uninstall) cmd_uninstall ;;
  ""|-h|--help|help) usage 0 ;;
  *) usage 1 ;;
esac
