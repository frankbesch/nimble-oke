#!/bin/bash
# Reliability tests for scripts/run_measured.sh. Stubs only: no real
# oci/kubectl/helm and no cloud call.
#   R4 SIGTERM during deploy -> rc 143, teardown exactly once
#   R5 SIGHUP during deploy  -> rc 129, teardown exactly once
#   R6 SIGKILL the runner during deploy -> watchdog tears down within 30 s
#   R7 teardown always fails -> rc non-zero, manual oci commands, watchdog armed
#   P1 pane close, gentle: HUP to the whole process group -> teardown once
#   P2 pane close, hard: INT, HUP, KILL to the group -> watchdog tears down
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="${REPO_ROOT}/scripts/run_measured.sh"
STUB_DIR="${REPO_ROOT}/tests/stubs"

TMP_DIR="$(mktemp -d)"
cleanup_tmp() {
  local f p
  for f in "${TMP_DIR}"/out*/watchdog.pid; do
    [[ -f "${f}" ]] || continue
    p="$(cat "${f}")"
    kill -KILL "${p}" 2>/dev/null || true
  done
  pkill -f "${TMP_DIR}/fakes/" 2>/dev/null || true
  [[ -n "${KEEP_TMP:-}" ]] || rm -rf "${TMP_DIR}"
}
trap cleanup_tmp EXIT

FAKE_DIR="${TMP_DIR}/fakes"
mkdir -p "${FAKE_DIR}"
export STUB_LOG="${TMP_DIR}/stub_calls.log"
export CALLS_LOG="${TMP_DIR}/fake_calls.log"
export PATH="${STUB_DIR}:${FAKE_DIR}:${PATH}"

export OCI_COMPARTMENT_ID="ocid1.compartment.oc1..testfake"
export NGC_API_KEY="test-key-not-real"
export POLL_SEC=1 READY_TIMEOUT_SEC=3 WATCHDOG_SEC=600 CLEANUP_RETRY_SEC=2
export TEARDOWN_RETRY_PAUSE_SEC=1 STEP_STOP_WAIT_SEC=5
# Step caps short enough that their sum (243) fits WATCHDOG_SEC=600.
export PROVISION_STEP_TIMEOUT_SEC=60 DEPLOY_STEP_TIMEOUT_SEC=120 BENCH_STEP_TIMEOUT_SEC=60

mkfake() {
  { echo '#!/bin/bash'; echo "echo \"$1 \$*\" >> \"\${CALLS_LOG}\""; echo "$2"; } > "${FAKE_DIR}/$1"
  chmod +x "${FAKE_DIR}/$1"
}
mkfake fake_preflight 'exit 0'
mkfake fake_provision 'exit 0'
mkfake fake_deploy 'sleep "${FAKE_DEPLOY_SLEEP:-30}"; echo "fake_deploy finished" >> "${CALLS_LOG}"; exit 0'
mkfake fake_ready 'exit 0'
mkfake fake_bench 'out=""; while [[ $# -gt 0 ]]; do [[ "$1" == "--out" ]] && out="$2"; shift; done; echo "{\"ok\": true}" > "${out}"; exit 0'
mkfake fake_teardown 'sleep "${FAKE_TEARDOWN_SLEEP:-0}"; exit "${FAKE_TEARDOWN_EXIT:-0}"'

export RUNNER_PREFLIGHT="${FAKE_DIR}/fake_preflight"
export RUNNER_PROVISION="${FAKE_DIR}/fake_provision"
export RUNNER_DEPLOY="${FAKE_DIR}/fake_deploy"
export RUNNER_READY="${FAKE_DIR}/fake_ready"
export RUNNER_BENCH="${FAKE_DIR}/fake_bench"
export RUNNER_TEARDOWN="${FAKE_DIR}/fake_teardown"

FAIL=0
reset() {
  : > "${STUB_LOG}"; : > "${CALLS_LOG}"
  unset FAKE_TEARDOWN_SLEEP FAKE_TEARDOWN_EXIT
  export FAKE_DEPLOY_SLEEP=30 STUB_CLUSTER=absent
}
count() { grep -c "^fake_$1" "${CALLS_LOG}" 2>/dev/null || true; }
wait_for_deploy() {  # until the deploy fake has started (max 10 s)
  for _ in $(seq 1 50); do grep -q "^fake_deploy" "${CALLS_LOG}" 2>/dev/null && return 0; sleep 0.2; done
  return 1
}
wd_alive() {
  local f="$1/watchdog.pid" p
  [[ -f "${f}" ]] || return 0
  p="$(cat "${f}")"
  for _ in 1 2 3 4 5 6; do kill -0 "${p}" 2>/dev/null || return 0; sleep 1; done
  echo "alive ${p}"
}
report() {
  if [[ "$2" == "true" ]]; then
    echo "$1 PASS  $3"
  else
    echo "$1 FAIL  $3"
    echo "--- phases.log ---"; cat "$4/phases.log" 2>/dev/null || true
    echo "--- trap.log ---"; cat "$4/trap.log" 2>/dev/null || true
    echo "--- watchdog.log ---"; cat "$4/watchdog.log" 2>/dev/null || true
    FAIL=1
  fi
}

signal_test() {  # $1 id, $2 signal, $3 expected rc
  reset
  local O="${TMP_DIR}/out$1" pid rc pass=true orphans
  "${RUNNER}" "${O}" > "${TMP_DIR}/$1.out" 2>&1 &
  pid=$!
  wait_for_deploy || pass=false
  kill "-$2" "${pid}"
  set +e; wait "${pid}"; rc=$?; set -e
  [[ "${rc}" -eq "$3" ]] || pass=false
  [[ "$(count teardown)" -eq 1 ]] || pass=false
  grep -q "fake_deploy finished" "${CALLS_LOG}" && pass=false
  [[ "$(count bench)" -eq 0 ]] || pass=false
  [[ -z "$(wd_alive "${O}")" ]] || pass=false
  orphans="$(pgrep -f "${FAKE_DIR}/fake_deploy" || true)"
  [[ -z "${orphans}" ]] || pass=false
  report "$1" "${pass}" "rc=${rc} (want $3) teardown_calls=$(count teardown) deploy_stopped=$(grep -q 'fake_deploy finished' "${CALLS_LOG}" && echo no || echo yes) orphan_deploy=[${orphans}] summary.signal=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["signal"])' "${O}/summary.json")" "${O}"
}

signal_test R4 TERM 143
signal_test R5 HUP 129

# --- R6: SIGKILL the runner during deploy -> watchdog tears down ---
reset
O="${TMP_DIR}/outR6"
"${RUNNER}" "${O}" > "${TMP_DIR}/R6.out" 2>&1 &
pid=$!
wait_for_deploy || true
t_kill=$(date +%s)
kill -KILL "${pid}"
set +e; wait "${pid}" 2>/dev/null; rc=$?; set -e
done_at=""
for _ in $(seq 1 30); do
  if tail -1 "${O}/watchdog.log" 2>/dev/null | grep -q "WATCHDOG FINAL"; then done_at=$(date +%s); break; fi
  sleep 1
done
pass=true
[[ -n "${done_at}" ]] || pass=false
tail -1 "${O}/watchdog.log" | grep -q "WATCHDOG FINAL: cleanup completed by watchdog" || pass=false
[[ "$(count teardown)" -eq 1 ]] || pass=false
orphans="$(pgrep -f "${FAKE_DIR}/fake_deploy" || true)"
[[ -z "${orphans}" ]] || pass=false
report R6 "${pass}" "runner rc=${rc} (SIGKILL) watchdog_done_after=$(( ${done_at:-9999} - t_kill ))s teardown_calls=$(count teardown) orphan_deploy=[${orphans}]" "${O}"
echo "  watchdog.log:"; sed 's/^/    /' "${O}/watchdog.log"

# --- R7: teardown always fails -> non-zero, manual commands, watchdog left armed ---
reset
O="${TMP_DIR}/outR7"
export FAKE_TEARDOWN_EXIT=1 STUB_CLUSTER=present FAKE_DEPLOY_SLEEP=0
set +e; r7_out="$("${RUNNER}" "${O}" 2>&1)"; rc=$?; set -e
pass=true
[[ "${rc}" -ne 0 ]] || pass=false
echo "${r7_out}" | grep -q "oci ce node-pool delete --node-pool-id" || pass=false
echo "${r7_out}" | grep -q "oci ce cluster delete --cluster-id" || pass=false
# The manual commands name the region explicitly (V1): OCI_REGION default us-phoenix-1.
echo "${r7_out}" | grep -q "oci ce node-pool delete --node-pool-id .* --region us-phoenix-1 " || pass=false
echo "${r7_out}" | grep -q "oci ce cluster delete --cluster-id .* --region us-phoenix-1 " || pass=false
echo "${r7_out}" | grep -q "WATCHDOG LEFT ARMED" || pass=false
[[ ! -f "${O}/.watchdog_stop" ]] || pass=false
wdpid="$(cat "${O}/watchdog.pid" 2>/dev/null || true)"
wd_ps="$(ps -p "${wdpid:-0}" -o pid= -o command= 2>/dev/null || true)"
[[ -n "${wd_ps}" ]] || pass=false
report R7 "${pass}" "rc=${rc} teardown_calls_by_runner=$(grep -c 'runner: teardown attempt .* exit' "${O}/runner.log") watchdog_after_runner_exit=[${wd_ps}]" "${O}"
echo "  runner stderr banner:"; echo "${r7_out}" | sed -n '/====/,/====/p' | sed 's/^/    /'
# The test's own cleanup of the deliberately armed watchdog:
if [[ -n "${wdpid}" ]]; then
  kill -TERM "${wdpid}" 2>/dev/null || true
  sleep 1
  kill -0 "${wdpid}" 2>/dev/null && kill -KILL "${wdpid}" 2>/dev/null
  echo "  killed armed watchdog ${wdpid}; alive now: $(kill -0 "${wdpid}" 2>/dev/null && echo yes || echo no)"
fi

# --- W1: watchdog deadline (WATCHDOG_SEC=3) during a long deploy -> TERM to runner -> rc 143, teardown once ---
reset
O="${TMP_DIR}/outW1"
set +e; WATCHDOG_SEC=3 ALLOW_SHORT_WATCHDOG=yes "${RUNNER}" "${O}" > "${TMP_DIR}/W1.out" 2>&1; rc=$?; set -e
sleep 2
pass=true
[[ "${rc}" -eq 143 ]] || pass=false
[[ "$(count teardown)" -eq 1 ]] || pass=false
grep -q "deadline 3s reached" "${O}/watchdog.log" || pass=false
tail -1 "${O}/watchdog.log" | grep -q "WATCHDOG FINAL: cleanup completed by runner" || pass=false
report W1 "${pass}" "rc=${rc} teardown_calls=$(count teardown) last=[$(tail -1 "${O}/watchdog.log" | cut -d' ' -f2-)]" "${O}"

# --- P1 / P2: pane close simulations (runner is its own process group via set -m) ---
pane_test() {  # $1 id, $2 "gentle" | "hard"
  reset
  local O="${TMP_DIR}/out$1" pid rc pass=true done_at="" t0 orphans
  # hard: a slow teardown, so the KILL lands while the runner's trap is
  # mid-teardown (as in a real pane close); the watchdog must finish it.
  [[ "$2" == "hard" ]] && export FAKE_TEARDOWN_SLEEP=3
  set -m
  "${RUNNER}" "${O}" > "${TMP_DIR}/$1.out" 2>&1 &
  pid=$!
  set +m
  wait_for_deploy || pass=false
  t0=$(date +%s)
  if [[ "$2" == "gentle" ]]; then
    kill -HUP -- "-${pid}" 2>/dev/null || true
  else
    kill -INT -- "-${pid}" 2>/dev/null || true
    kill -HUP -- "-${pid}" 2>/dev/null || true
    sleep 1
    kill -KILL -- "-${pid}" 2>/dev/null || true
  fi
  set +e; wait "${pid}" 2>/dev/null; rc=$?; set -e
  for _ in $(seq 1 30); do
    if tail -1 "${O}/watchdog.log" 2>/dev/null | grep -q "WATCHDOG FINAL"; then done_at=$(date +%s); break; fi
    sleep 1
  done
  [[ -n "${done_at}" ]] || pass=false
  tail -1 "${O}/watchdog.log" | grep -q "WATCHDOG FINAL: cleanup completed" || pass=false
  [[ -f "${O}/CLEANUP_COMPLETE" ]] || pass=false
  if [[ "$2" == "gentle" ]]; then
    [[ "$(count teardown)" -eq 1 ]] || pass=false
  else
    # one teardown killed mid-run with the runner, one completed by the watchdog
    [[ "$(count teardown)" -eq 2 ]] || pass=false
    grep -q "by watchdog" "${O}/CLEANUP_COMPLETE" 2>/dev/null || pass=false
  fi
  orphans="$(pgrep -f "${FAKE_DIR}/fake_" || true)"
  [[ -z "${orphans}" ]] || pass=false
  report "$1" "${pass}" "$2: runner rc=${rc} final_after=$(( ${done_at:-9999} - t0 ))s teardown_calls=$(count teardown) marker=[$(cat "${O}/CLEANUP_COMPLETE" 2>/dev/null)] last=[$(tail -1 "${O}/watchdog.log" | cut -d' ' -f2-)]" "${O}"
}
pane_test P1 gentle
pane_test P2 hard

if [[ "${FAIL}" -ne 0 ]]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: all passed"
