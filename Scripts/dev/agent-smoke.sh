#!/usr/bin/env bash
#
# Hermetic end-to-end smoke for the user-level Kumo agent tier ("kumod").
#
# Sequence:
#   fresh /tmp app-support -> install -> socket 0600 -> signed ping 200 ->
#   idle self-exit -> on-demand relaunch (timing) -> uninstall -> assert the
#   launchd job, plist, socket and app-support tree are gone.
#
# Refuses to run without KUMO_APP_SUPPORT_DIR + KUMO_AGENT_LABEL, refuses the
# production path/label, and trap-cleans on any failure.
#
# Usage:
#   KUMO_APP_SUPPORT_DIR=/tmp/kumo-agent-smoke \
#   KUMO_AGENT_LABEL=io.kumo.KumoAgent.dev \
#   Scripts/dev/agent-smoke.sh
#
# Optional env: KUMO_SMOKE_IDLE_TIMEOUT (default 3), KUMO_SMOKE_DEADLINE_MS
# (default 30000), KUMO_DEV_SKIP_BUILD=1 to reuse the built binary.
#
# See docs/quality/testing-quality.md (L1 layer).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTANCE="${REPO_ROOT}/Scripts/dev/agent-instance.sh"
SERVICE_BIN="${KUMO_DEV_SERVICE_BIN:-${REPO_ROOT}/.build/debug/KumoService}"

PRODUCTION_APP_SUPPORT="${HOME}/Library/Application Support/Kumo"
PRODUCTION_AGENT_LABEL="io.kumo.KumoAgent"

IDLE_TIMEOUT="${KUMO_SMOKE_IDLE_TIMEOUT:-3}"
DEADLINE_MS="${KUMO_SMOKE_DEADLINE_MS:-30000}"

if [[ -z "${KUMO_APP_SUPPORT_DIR:-}" ]]; then
  echo "refusing: KUMO_APP_SUPPORT_DIR is not set. Export a disposable /tmp path," >&2
  echo "          e.g. KUMO_APP_SUPPORT_DIR=/tmp/kumo-agent-smoke." >&2
  exit 2
fi
if [[ -z "${KUMO_AGENT_LABEL:-}" ]]; then
  echo "refusing: KUMO_AGENT_LABEL is not set. Export the dev launchd label," >&2
  echo "          e.g. KUMO_AGENT_LABEL=io.kumo.KumoAgent.dev." >&2
  exit 2
fi

realpath_dir() {
  python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

now_ms() {
  perl -MTime::HiRes=time -e 'printf "%.0f", time * 1000'
}

APP_SUPPORT="$(realpath_dir "${KUMO_APP_SUPPORT_DIR}")"
LABEL="${KUMO_AGENT_LABEL}"
TMP_ROOT="$(realpath_dir "${KUMO_SMOKE_TMP_ROOT:-/tmp}")"

if [[ "${APP_SUPPORT}" == "$(realpath_dir "${PRODUCTION_APP_SUPPORT}")" ]]; then
  echo "refusing: app-support resolves to the production root ${APP_SUPPORT}." >&2
  exit 2
fi
if [[ "${LABEL}" == "${PRODUCTION_AGENT_LABEL}" ]]; then
  echo "refusing: KUMO_AGENT_LABEL is the production label ${LABEL}." >&2
  exit 2
fi
if [[ ! "${LABEL}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "refusing: KUMO_AGENT_LABEL '${LABEL}' is not a valid launchd label." >&2
  exit 2
fi
if [[ "${APP_SUPPORT}" != "${TMP_ROOT}"/* ]]; then
  echo "refusing: app-support ${APP_SUPPORT} is not under ${TMP_ROOT}; the smoke test wipes it." >&2
  exit 2
fi

export KUMO_APP_SUPPORT_DIR="${APP_SUPPORT}"
export KUMO_AGENT_LABEL="${LABEL}"

SOCKET="${APP_SUPPORT}/kumo-agent.sock"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"

CLEANUP_ARMED=0

fail() {
  echo "SMOKE FAILED: $*" >&2
  exit 1
}

cleanup() {
  local status=$?
  trap - EXIT
  if [[ "${CLEANUP_ARMED}" == "1" ]]; then
    "${INSTANCE}" uninstall >/dev/null 2>&1 || true
    launchctl bootout "gui/${UID}/${LABEL}" >/dev/null 2>&1 || true
    rm -f "${PLIST}" "${SOCKET}" 2>/dev/null || true
    if [[ "${status}" -ne 0 ]]; then
      echo "keeping failed-run logs for inspection: ${APP_SUPPORT}/logs" >&2
    fi
  fi
  if [[ "${status}" -ne 0 ]]; then
    echo "SMOKE FAILED (exit ${status})" >&2
  fi
  exit "${status}"
}
trap cleanup EXIT

job_pid() {
  launchctl print "gui/${UID}/${LABEL}" 2>/dev/null \
    | sed -n 's/^[[:space:]]*pid = \([0-9][0-9]*\).*$/\1/p' \
    | head -1 || true
}

assert_signed_ping() {
  local status_json
  status_json="$("${SERVICE_BIN}" service status --mode user --app-support "${APP_SUPPORT}")"
  if ! python3 -c 'import json, sys
data = json.loads(sys.argv[1])
sys.exit(0 if data.get("isRunning") and data.get("isAvailable") else 1)' "${status_json}"; then
    fail "signed ping did not report a running agent: ${status_json}"
  fi
  printf '%s\n' "${status_json}"
}

echo "== Kumo agent L1 smoke =="
echo "app-support:  ${APP_SUPPORT}"
echo "label:        ${LABEL}"
echo "idle-timeout: ${IDLE_TIMEOUT}s"

# 1. Fresh disposable app-support tree.
rm -rf -- "${APP_SUPPORT}"
mkdir -p -- "${APP_SUPPORT}"
CLEANUP_ARMED=1

# 2. Install (builds KumoService incrementally when needed).
install_start=$(now_ms)
KUMO_DEV_IDLE_TIMEOUT="${IDLE_TIMEOUT}" "${INSTANCE}" install
install_ms=$(( $(now_ms) - install_start ))
echo "install: ${install_ms} ms"

# 3. launchd must have created the 0600 socket and the dev plist.
socket_deadline=$(( $(now_ms) + DEADLINE_MS ))
while [[ ! -S "${SOCKET}" ]]; do
  if (( $(now_ms) > socket_deadline )); then
    fail "socket ${SOCKET} did not appear after install"
  fi
  sleep 0.1
done
[[ -f "${PLIST}" ]] || fail "plist ${PLIST} was not written"
socket_mode="$(stat -f '%Lp' "${SOCKET}")"
[[ "${socket_mode}" == "600" ]] || fail "socket mode is ${socket_mode}, expected 600"
echo "socket 0600:  ok (${SOCKET})"

# 4. Signed ping (HMAC via KumoServiceClient inside the status command).
ping_start=$(now_ms)
ping_first="$(assert_signed_ping)"
ping_ms=$(( $(now_ms) - ping_start ))
echo "signed ping:  200 (${ping_ms} ms)"
echo "  ${ping_first}"
pid_before="$(job_pid)"
[[ -n "${pid_before}" ]] || fail "launchd reports no agent pid after the first ping"

# 5. Idle self-exit: the agent must leave on its own once traffic stops.
echo "waiting for idle self-exit..."
idle_start=$(now_ms)
idle_deadline=$(( idle_start + DEADLINE_MS ))
while [[ -n "$(job_pid)" ]]; do
  if (( $(now_ms) > idle_deadline )); then
    fail "agent (pid ${pid_before}) is still running after ${DEADLINE_MS} ms"
  fi
  sleep 0.2
done
idle_ms=$(( $(now_ms) - idle_start ))
echo "idle exit:    ${idle_ms} ms after last request (timeout ${IDLE_TIMEOUT}s)"

# 6. First new connection must relaunch the agent through launchd.
relaunch_start=$(now_ms)
ping_second="$(assert_signed_ping)"
relaunch_ms=$(( $(now_ms) - relaunch_start ))
pid_after="$(job_pid)"
[[ -n "${pid_after}" ]] || fail "launchd reports no agent pid after relaunch"
[[ "${pid_after}" != "${pid_before}" ]] || fail "agent pid did not change across idle exit"
echo "relaunch:     ${relaunch_ms} ms (pid ${pid_before} -> ${pid_after})"
echo "  ${ping_second}"

# 7. Uninstall and prove every dev artifact is gone.
"${INSTANCE}" uninstall
if [[ -e "${PLIST}" ]]; then fail "plist still present: ${PLIST}"; fi
if [[ -e "${SOCKET}" ]]; then fail "socket still present: ${SOCKET}"; fi
if launchctl print "gui/${UID}/${LABEL}" >/dev/null 2>&1; then
  fail "launchd job still registered: gui/${UID}/${LABEL}"
fi
if launchctl print "gui/${UID}" 2>/dev/null | grep -q "${LABEL}"; then
  fail "launchctl domain gui/${UID} still lists ${LABEL}"
fi
rm -rf -- "${APP_SUPPORT}"
if [[ -e "${APP_SUPPORT}" ]]; then fail "app-support tree still present: ${APP_SUPPORT}"; fi

trap - EXIT
echo "== SMOKE PASS =="
