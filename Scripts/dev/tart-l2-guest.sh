#!/usr/bin/env bash
# Guest-side phases for tart-l2-smoke.sh. This file runs only inside the
# disposable Tart guest; never execute it on the host.

set -euo pipefail

DIR="${KUMO_L2_DIR:-/tmp/kumo-l2}"
KUMO="${DIR}/kumo"
SERVICE="${DIR}/KumoService"
APP_SUPPORT="${HOME}/Library/Application Support/Kumo"
RESULTS="${DIR}/results"
PASSWORD_FILE="${DIR}/.vm-password"
PROBE_URL="https://www.apple.com"

mkdir -p "${RESULTS}"

fatal() {
  echo "GUEST ASSERTION FAILED: $*" >&2
  exit 1
}

assert_eq() {
  local actual="$1" expected="$2" message="$3"
  [[ "${actual}" == "${expected}" ]] || fatal "${message}: expected '${expected}', got '${actual}'"
}

json_get() {
  /usr/bin/plutil -extract "$1" raw -o - "$2"
}

sudo_cmd() {
  printf '%s\n' "${PASSWORD}" | /usr/bin/sudo -S -p '' "$@"
}

http_probe() {
  local label="$1"
  local code
  code="$(curl -4 -sS --max-time 20 -o /dev/null -w '%{http_code}' "${PROBE_URL}")"
  assert_eq "${code}" "200" "${label} HTTPS traversal"
  echo "PASS: ${label} HTTPS traversal (HTTP ${code})"
}

wait_for_service() {
  local output="$1"
  for _ in {1..30}; do
    if "${KUMO}" service status --json >"${output}" 2>/dev/null; then
      if [[ "$(json_get data.isRunning "${output}" 2>/dev/null || true)" == "true" ]]; then
        return 0
      fi
    fi
    sleep 1
  done
  fatal "Privileged service did not become reachable"
}

wait_for_new_core() {
  local old_pid="$1" output="$2"
  for _ in {1..35}; do
    if "${KUMO}" status --json >"${output}" 2>/dev/null; then
      local state pid
      state="$(json_get data.state "${output}" 2>/dev/null || true)"
      pid="$(json_get data.pid "${output}" 2>/dev/null || true)"
      if [[ "${state}" == "running" && -n "${pid}" && "${pid}" != "${old_pid}" ]]; then
        printf '%s\n' "${pid}"
        return 0
      fi
    fi
    sleep 1
  done
  return 1
}

write_candidates() {
  cat >"${DIR}/candidate.yaml" <<'YAML'
proxies: []
proxy-groups: []
rules:
  - DOMAIN,example.com,DIRECT
  - MATCH,DIRECT
YAML
  cat >"${DIR}/invalid.yaml" <<'YAML'
proxies: [
  this-is-not-valid-yaml
rules:
  - MATCH,DIRECT
YAML
}

setup() {
  echo "Guest: $(sw_vers -productVersion) ($(uname -m))"
  "${DIR}/mihomo" -v | head -n 1
  rm -rf "${APP_SUPPORT}"
  mkdir -p "${APP_SUPPORT}/cores"
  cp "${DIR}/mihomo" "${APP_SUPPORT}/cores/mihomo"
  chmod 755 "${APP_SUPPORT}/cores/mihomo"

  local key_id shared_secret
  key_id="$(uuidgen)"
  shared_secret="$(uuidgen)$(uuidgen)"
  printf '{"keyID":"%s","sharedSecret":"%s"}\n' "${key_id}" "${shared_secret}" >"${APP_SUPPORT}/service-credentials.json"
  chmod 600 "${APP_SUPPORT}/service-credentials.json"

  sudo_cmd "${SERVICE}" service install \
    --source "${SERVICE}" \
    --app-support "${APP_SUPPORT}" \
    --authorized-uid "$(id -u)" \
    --key-id "${key_id}" \
    --shared-secret "${shared_secret}"
  wait_for_service "${RESULTS}/service-ready.json"
  assert_eq "$(stat -f '%Lp' "${APP_SUPPORT}/kumo-service.sock")" "600" "Root socket permissions"

  "${KUMO}" start --json >"${RESULTS}/start.json"
  "${KUMO}" status --json >"${RESULTS}/root-started.json"
  assert_eq "$(json_get data.state "${RESULTS}/root-started.json")" "running" "Initial core state"
  assert_eq "$(json_get data.ownerTier "${RESULTS}/root-started.json")" "rootService" "Initial core owner"
  echo "PASS: real root LaunchDaemon, signed socket and rootService core ownership"
}

acceptance() {
  echo "== System proxy apply and cleanup =="
  "${KUMO}" sysproxy on --json >"${RESULTS}/proxy-on.json"
  "${KUMO}" sysproxy status --json >"${RESULTS}/proxy-owned.json"
  assert_eq "$(json_get data.ownership "${RESULTS}/proxy-owned.json")" "owned" "System proxy ownership"
  local network_service
  network_service="$(json_get data.applied.networkService "${RESULTS}/proxy-owned.json")"
  http_probe "system proxy"
  "${KUMO}" sysproxy off --json >"${RESULTS}/proxy-off.json"
  echo "PASS: system proxy apply and disable"

  echo "== MIPS TUN route installation =="
  "${KUMO}" tun settings --json >"${RESULTS}/tun-defaults.json"
  assert_eq "$(json_get data.stack "${RESULTS}/tun-defaults.json")" "mips" "Default TUN stack"
  "${KUMO}" tun enable --json >"${RESULTS}/tun-enable.json"
  sleep 3
  "${KUMO}" status --json >"${RESULTS}/tun-running.json"
  assert_eq "$(json_get data.tunStatus.isRunning "${RESULTS}/tun-running.json")" "true" "Running TUN state"
  assert_eq "$(json_get data.runtimeSettings.tun.stack "${RESULTS}/tun-running.json")" "mips" "Runtime TUN stack"
  netstat -rn -f inet >"${RESULTS}/tun-routes.txt"
  grep -q '198\.18\.0\.1' "${RESULTS}/tun-routes.txt" || fatal "Mihomo split routes are absent"
  local tun_interface
  tun_interface="$(awk '/198\.18\.0\.1/ && $NF ~ /^utun/ { print $NF; exit }' "${RESULTS}/tun-routes.txt")"
  [[ -n "${tun_interface}" ]] || fatal "No utun interface owns the Mihomo routes"
  echo "PASS: MIPS TUN routes installed on ${tun_interface}"
  http_probe "TUN"

  echo "== Configuration preflight, apply and rollback =="
  write_candidates
  "${KUMO}" status --json >"${RESULTS}/before-transaction.json"
  local original_pid
  original_pid="$(json_get data.pid "${RESULTS}/before-transaction.json")"
  "${KUMO}" config validate --file "${DIR}/invalid.yaml" --json >"${RESULTS}/invalid-validation.json"
  assert_eq "$(json_get data.valid "${RESULTS}/invalid-validation.json")" "false" "Invalid candidate diagnostic"
  if "${KUMO}" config apply --file "${DIR}/invalid.yaml" --json >"${RESULTS}/invalid-apply.json" 2>&1; then
    fatal "Invalid configuration unexpectedly applied"
  fi
  "${KUMO}" status --json >"${RESULTS}/after-invalid.json"
  assert_eq "$(json_get data.pid "${RESULTS}/after-invalid.json")" "${original_pid}" "PID after rejected apply"

  "${KUMO}" config diff --file "${DIR}/candidate.yaml" --json >"${RESULTS}/candidate-diff.json"
  assert_eq "$(json_get data.changed "${RESULTS}/candidate-diff.json")" "true" "Candidate diff"
  "${KUMO}" config validate --file "${DIR}/candidate.yaml" --json >"${RESULTS}/candidate-validation.json"
  assert_eq "$(json_get data.valid "${RESULTS}/candidate-validation.json")" "true" "Valid candidate diagnostic"
  "${KUMO}" config apply --file "${DIR}/candidate.yaml" --json >"${RESULTS}/candidate-apply.json"
  assert_eq "$(json_get data.reloaded "${RESULTS}/candidate-apply.json")" "true" "Apply hot reload"
  "${KUMO}" status --json >"${RESULTS}/after-apply.json"
  assert_eq "$(json_get data.pid "${RESULTS}/after-apply.json")" "${original_pid}" "PID after valid apply"
  "${KUMO}" config rollback --json >"${RESULTS}/rollback.json"
  assert_eq "$(json_get data.reloaded "${RESULTS}/rollback.json")" "true" "Rollback hot reload"
  "${KUMO}" status --json >"${RESULTS}/after-rollback.json"
  assert_eq "$(json_get data.pid "${RESULTS}/after-rollback.json")" "${original_pid}" "PID after rollback"
  echo "PASS: invalid apply preserved PID ${original_pid}; valid apply and rollback hot-reloaded"
  http_probe "post-rollback TUN"

  echo "== Unexpected core exit and bounded recovery =="
  sudo_cmd kill -9 "${original_pid}"
  local recovered_pid
  recovered_pid="$(wait_for_new_core "${original_pid}" "${RESULTS}/after-crash.json")" || fatal "Core did not recover after SIGKILL"
  assert_eq "$(json_get data.lastExit.expected "${RESULTS}/after-crash.json")" "false" "Unexpected-exit classification"
  assert_eq "$(json_get data.lastExit.signal "${RESULTS}/after-crash.json")" "9" "Unexpected-exit signal"
  assert_eq "$(json_get data.lastExit.pid "${RESULTS}/after-crash.json")" "${original_pid}" "Unexpected-exit PID"
  grep -q 'Recovery attempt 1 of 3 scheduled in 2\.0 seconds' "${APP_SUPPORT}/logs/runtime-events.jsonl" \
    || fatal "Expected two-second recovery event is absent"
  echo "PASS: core recovered from SIGKILL (${original_pid} -> ${recovered_pid})"
  http_probe "post-crash TUN"

  echo "== TUN cleanup and system proxy Reclaim =="
  "${KUMO}" tun disable --json >"${RESULTS}/tun-disable.json"
  sleep 3
  netstat -rn -f inet >"${RESULTS}/direct-routes.txt"
  if grep -q '198\.18\.0\.1' "${RESULTS}/direct-routes.txt"; then
    fatal "Mihomo split routes remain after TUN disable"
  fi
  http_probe "direct network after TUN disable"

  "${KUMO}" sysproxy on --json >"${RESULTS}/proxy-reclaim-on.json"
  networksetup -setwebproxy "${network_service}" 127.0.0.1 9999
  "${KUMO}" sysproxy status --json >"${RESULTS}/proxy-taken-over.json"
  assert_eq "$(json_get data.ownership "${RESULTS}/proxy-taken-over.json")" "takenOver" "External proxy takeover"
  "${KUMO}" sysproxy reclaim --json >"${RESULTS}/proxy-reclaim.json"
  "${KUMO}" sysproxy status --json >"${RESULTS}/proxy-reclaimed.json"
  assert_eq "$(json_get data.ownership "${RESULTS}/proxy-reclaimed.json")" "owned" "Reclaimed proxy ownership"
  "${KUMO}" sysproxy off --json >"${RESULTS}/proxy-reclaim-off.json"
  echo "PASS: external takeover detected and Reclaim restored Kumo settings"

  echo "== Root daemon restart =="
  "${KUMO}" status --json >"${RESULTS}/before-daemon-restart.json"
  local before_restart_pid after_restart_pid
  before_restart_pid="$(json_get data.pid "${RESULTS}/before-daemon-restart.json")"
  sudo_cmd launchctl kickstart -k system/io.kumo.KumoService
  wait_for_service "${RESULTS}/service-restarted.json"
  "${KUMO}" status --json >"${RESULTS}/after-daemon-restart.json"
  after_restart_pid="$(json_get data.pid "${RESULTS}/after-daemon-restart.json")"
  assert_eq "${after_restart_pid}" "${before_restart_pid}" "Core PID across daemon restart"
  assert_eq "$(json_get data.state "${RESULTS}/after-daemon-restart.json")" "running" "Core state after daemon restart"
  echo "PASS: root daemon restart preserved core PID ${before_restart_pid}"
  http_probe "post-daemon-restart network"
}

cleanup() {
  local failed=0
  if [[ -x "${KUMO}" ]]; then
    "${KUMO}" sysproxy off --json >/dev/null 2>&1 || true
    "${KUMO}" stop --json >"${RESULTS}/cleanup-stop.json" 2>&1 || failed=1
  fi
  if [[ -x "${SERVICE}" ]]; then
    sudo_cmd "${SERVICE}" service uninstall --app-support "${APP_SUPPORT}" >/dev/null 2>&1 || failed=1
  fi
  [[ ! -e /Library/LaunchDaemons/io.kumo.KumoService.plist ]] || failed=1
  [[ ! -e /Library/PrivilegedHelperTools/io.kumo.KumoService ]] || failed=1
  if [[ "${failed}" -ne 0 ]]; then
    echo "Guest cleanup did not complete cleanly." >&2
    return 1
  fi
  echo "PASS: core stopped and privileged helper removed"
}

[[ -f "${DIR}/.disposable-tart-guest" ]] \
  || fatal "Refusing to run without the disposable Tart guest marker"
[[ -f "${PASSWORD_FILE}" ]] || fatal "Guest password file is missing"
PASSWORD="$(<"${PASSWORD_FILE}")"

case "${1:-}" in
  setup) setup ;;
  acceptance) acceptance ;;
  cleanup) cleanup ;;
  *) fatal "Unknown guest phase: ${1:-<empty>}" ;;
esac
