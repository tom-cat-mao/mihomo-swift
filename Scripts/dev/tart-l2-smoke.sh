#!/usr/bin/env bash
#
# Disposable Tart L2 acceptance for the real root daemon, system proxy, TUN,
# configuration transactions and unexpected-exit recovery.
#
# The host application-support tree, launchd jobs and /Applications are never
# modified. A uniquely named VM clone is created and always deleted, including
# after failure. Guest logs are retained under build/l2-acceptance/.
#
# Usage:
#   Scripts/dev/tart-l2-smoke.sh
#
# Optional environment:
#   KUMO_TART_BASE_VM       Base image (default: NJU mirror of macos-tahoe-base)
#   KUMO_TART_VM_NAME       Clone name (default: kumo-l2-<pid>; must not exist)
#   KUMO_TART_VM_USER       Guest SSH user (default: admin)
#   KUMO_TART_VM_PASSWORD   Guest SSH/sudo password (default: admin)
#   KUMO_MIHOMO_PATH        Core to copy (default: host managed core or PATH)
#   KUMO_L2_SKIP_BUILD=1    Reuse .build/release/kumo and KumoService
#   KUMO_TART_GRAPHICS=1    Show Tart GUI instead of running headlessly
#   KUMO_L2_ARTIFACT_DIR    Log/staging root (default: build/l2-acceptance)
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE_VM="${KUMO_TART_BASE_VM:-ghcr.nju.edu.cn/cirruslabs/macos-tahoe-base:latest}"
VM_NAME="${KUMO_TART_VM_NAME:-kumo-l2-$$}"
VM_USER="${KUMO_TART_VM_USER:-admin}"
VM_PASSWORD="${KUMO_TART_VM_PASSWORD:-admin}"
ARTIFACT_ROOT="${KUMO_L2_ARTIFACT_DIR:-${REPO_ROOT}/build/l2-acceptance}"
RUN_DIR="${ARTIFACT_ROOT}/$(date '+%Y%m%d-%H%M%S')-$$"
STAGING_DIR="${RUN_DIR}/payload"
PAYLOAD_FILE="${RUN_DIR}/kumo-l2-payload.tar"
REMOTE_DIR="/tmp/kumo-l2"
GUEST_SCRIPT="${REPO_ROOT}/Scripts/dev/tart-l2-guest.sh"

VM_CREATED=0
VM_IP=""
TART_RUN_PID=""
PAYLOAD_UPLOADED=0

log() {
  printf '\n== %s ==\n' "$*"
}

fatal() {
  echo "error: $*" >&2
  exit 1
}

resolve_core() {
  if [[ -n "${KUMO_MIHOMO_PATH:-}" ]]; then
    [[ -x "${KUMO_MIHOMO_PATH}" ]] || fatal "KUMO_MIHOMO_PATH is not executable: ${KUMO_MIHOMO_PATH}"
    printf '%s\n' "${KUMO_MIHOMO_PATH}"
    return
  fi

  local managed="${HOME}/Library/Application Support/Kumo/cores/mihomo"
  if [[ -x "${managed}" ]]; then
    printf '%s\n' "${managed}"
    return
  fi

  local discovered
  discovered="$(command -v mihomo || true)"
  [[ -n "${discovered}" ]] || fatal "Mihomo not found; set KUMO_MIHOMO_PATH to an executable darwin/arm64 core."
  printf '%s\n' "${discovered}"
}

vm_ssh() {
  local remote_command="$1"
  KUMO_VM_PASSWORD="${VM_PASSWORD}" expect -f - "${VM_USER}@${VM_IP}" "${remote_command}" <<'EXPECT'
set timeout 240
set remote_host [lindex $argv 0]
set remote_command [lindex $argv 1]
spawn ssh -o ConnectTimeout=8 -o ConnectionAttempts=1 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $remote_host $remote_command
expect {
    -nocase "password:" { send -- "$env(KUMO_VM_PASSWORD)\r" }
    eof { exit 125 }
    timeout { exit 124 }
}
expect {
    eof {}
    -nocase "password:" { exit 125 }
    timeout { exit 124 }
}
set result [wait]
exit [lindex $result 3]
EXPECT
}

vm_upload_payload() {
  KUMO_VM_PASSWORD="${VM_PASSWORD}" expect -f - "${PAYLOAD_FILE}" "${VM_USER}@${VM_IP}" <<'EXPECT'
set timeout 240
set payload [lindex $argv 0]
set remote_host [lindex $argv 1]
spawn scp -o ConnectTimeout=8 -o ConnectionAttempts=1 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $payload $remote_host:/tmp/kumo-l2-payload.tar
expect {
    -nocase "password:" { send -- "$env(KUMO_VM_PASSWORD)\r" }
    eof { exit 125 }
    timeout { exit 124 }
}
expect {
    eof {}
    -nocase "password:" { exit 125 }
    timeout { exit 124 }
}
set result [wait]
exit [lindex $result 3]
EXPECT
}

vm_download_results() {
  KUMO_VM_PASSWORD="${VM_PASSWORD}" expect -f - "${VM_USER}@${VM_IP}" "${RUN_DIR}/guest-results.tar" <<'EXPECT'
set timeout 240
set remote_host [lindex $argv 0]
set local_archive [lindex $argv 1]
spawn scp -o ConnectTimeout=8 -o ConnectionAttempts=1 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $remote_host:/tmp/kumo-l2-results.tar $local_archive
expect {
    -nocase "password:" { send -- "$env(KUMO_VM_PASSWORD)\r" }
    eof { exit 125 }
    timeout { exit 124 }
}
expect {
    eof {}
    -nocase "password:" { exit 125 }
    timeout { exit 124 }
}
set result [wait]
exit [lindex $result 3]
EXPECT
}

guest_phase() {
  local phase="$1"
  vm_ssh "KUMO_L2_DIR='${REMOTE_DIR}' bash '${REMOTE_DIR}/guest.sh' '${phase}'"
}

collect_guest_results() {
  if vm_ssh "tar -cf /tmp/kumo-l2-results.tar -C '${REMOTE_DIR}' results" >/dev/null 2>&1 \
    && vm_download_results >/dev/null 2>&1; then
    tar -xf "${RUN_DIR}/guest-results.tar" -C "${RUN_DIR}"
  else
    echo "warning: unable to collect detailed guest results." >&2
  fi
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM

  if [[ "${PAYLOAD_UPLOADED}" == "1" && -n "${VM_IP}" ]]; then
    collect_guest_results
    echo "Cleaning guest core, proxy state and privileged helper..."
    if ! guest_phase cleanup 2>&1 | tee "${RUN_DIR}/guest-cleanup.log"; then
      echo "warning: guest cleanup failed; deleting the disposable VM anyway." >&2
      if [[ "${status}" -eq 0 ]]; then status=1; fi
    fi
  fi

  if [[ "${VM_CREATED}" == "1" ]]; then
    tart stop "${VM_NAME}" --timeout 30 >/dev/null 2>&1 || true
    if ! tart delete "${VM_NAME}" >/dev/null 2>&1; then
      echo "warning: failed to delete disposable VM ${VM_NAME}." >&2
      if [[ "${status}" -eq 0 ]]; then status=1; fi
    fi
  fi
  if [[ -n "${TART_RUN_PID}" ]]; then
    wait "${TART_RUN_PID}" >/dev/null 2>&1 || true
  fi
  rm -rf "${STAGING_DIR}"
  rm -f "${PAYLOAD_FILE}"

  if [[ "${status}" -eq 0 ]]; then
    echo "L2 PASS: disposable VM removed; logs: ${RUN_DIR}"
  else
    echo "L2 FAILED (exit ${status}); logs: ${RUN_DIR}" >&2
  fi
  exit "${status}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[[ "$(uname -s)" == "Darwin" ]] || fatal "The Tart L2 smoke must run on macOS."
[[ "$(uname -m)" == "arm64" ]] || fatal "The default Tart macOS guest requires an arm64 host."
for command in tart expect ssh scp swift tar; do
  command -v "${command}" >/dev/null 2>&1 || fatal "Required command not found: ${command}"
done
[[ -f "${GUEST_SCRIPT}" ]] || fatal "Guest script not found: ${GUEST_SCRIPT}"

if tart list | awk -v name="${VM_NAME}" '$2 == name { found = 1 } END { exit found ? 0 : 1 }'; then
  fatal "Refusing to replace existing Tart VM: ${VM_NAME}"
fi

mkdir -p "${STAGING_DIR}"
echo "Logs: ${RUN_DIR}"

if [[ "${KUMO_L2_SKIP_BUILD:-0}" != "1" ]]; then
  log "Building release CLI and privileged helper"
  (cd "${REPO_ROOT}" && swift build -c release --product kumo && swift build -c release --product KumoService)
fi
for product in kumo KumoService; do
  [[ -x "${REPO_ROOT}/.build/release/${product}" ]] || fatal "Missing release product: ${product}"
  cp "${REPO_ROOT}/.build/release/${product}" "${STAGING_DIR}/${product}"
done

CORE_PATH="$(resolve_core)"
log "Preparing disposable payload"
echo "Core: ${CORE_PATH}"
cp "${CORE_PATH}" "${STAGING_DIR}/mihomo"
cp "${GUEST_SCRIPT}" "${STAGING_DIR}/guest.sh"
printf '%s\n' "${VM_NAME}" >"${STAGING_DIR}/.disposable-tart-guest"
printf '%s' "${VM_PASSWORD}" >"${STAGING_DIR}/.vm-password"
chmod 600 "${STAGING_DIR}/.vm-password"
chmod 755 "${STAGING_DIR}/kumo" "${STAGING_DIR}/KumoService" "${STAGING_DIR}/mihomo" "${STAGING_DIR}/guest.sh"
tar -cf "${PAYLOAD_FILE}" -C "${STAGING_DIR}" .

log "Cloning ${BASE_VM} to ${VM_NAME}"
tart clone "${BASE_VM}" "${VM_NAME}"
VM_CREATED=1

log "Starting disposable VM"
run_options=(run "${VM_NAME}" --no-audio --no-clipboard)
if [[ "${KUMO_TART_GRAPHICS:-0}" != "1" ]]; then
  run_options+=(--no-graphics)
fi
tart "${run_options[@]}" >"${RUN_DIR}/tart-run.log" 2>&1 &
TART_RUN_PID=$!
VM_IP="$(tart ip "${VM_NAME}" --wait 120)"
[[ "${VM_IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || fatal "Unexpected guest IP: ${VM_IP}"
echo "Guest IP: ${VM_IP}"

SSH_READY=0
for _ in {1..30}; do
  if vm_ssh true >/dev/null 2>&1; then
    SSH_READY=1
    break
  fi
  sleep 2
done
[[ "${SSH_READY}" == "1" ]] || fatal "Guest SSH did not become ready."

log "Uploading release binaries and guest acceptance"
vm_upload_payload >/dev/null
vm_ssh "rm -rf '${REMOTE_DIR}'; mkdir -p '${REMOTE_DIR}'; tar -xf /tmp/kumo-l2-payload.tar -C '${REMOTE_DIR}'; chmod 755 '${REMOTE_DIR}/kumo' '${REMOTE_DIR}/KumoService' '${REMOTE_DIR}/mihomo' '${REMOTE_DIR}/guest.sh'"
PAYLOAD_UPLOADED=1

log "Installing root service and starting Mihomo"
guest_phase setup 2>&1 | tee "${RUN_DIR}/guest-setup.log"

log "Running root, proxy, TUN, transaction and crash acceptance"
guest_phase acceptance 2>&1 | tee "${RUN_DIR}/guest-acceptance.log"

log "All guest assertions passed"
