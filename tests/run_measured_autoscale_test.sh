#!/bin/bash
# Tests for scripts/run_measured.sh --autoscale (GPU node autoscaling 0->1->0)
# and the deploy.sh / prereqs.sh autoscale exemption. Stubs only: no real
# oci/kubectl/helm and no cloud call. tests/stubs/ is first on PATH; the stub
# kubectl emulates the cluster autoscaler when STUB_AS_DIR is set.
#   U1 happy path            U2 no scale-up (NotTriggerScaleUp)  U3 node never leaves
#   U4 IAM check fails       U5 SIGTERM during scale-up          U6 SIGKILL during scale-down
#   U7 MAX_GPU_NODES=2       U8 fixed-mode regression            U9 deploy.sh AUTOSCALE=1
#   PC tests/pane_close_check.sh --autoscale, pane close simulated (INT+HUP, then KILL)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="${REPO_ROOT}/scripts/run_measured.sh"
STUB_DIR="${REPO_ROOT}/tests/stubs"

TMP_DIR="$(mktemp -d)"
cleanup_tmp() {
  local f p
  for f in "${TMP_DIR}"/out*/watchdog.pid "${TMP_DIR}"/pane-close-check.*/out/watchdog.pid; do
    [[ -f "${f}" ]] || continue
    p="$(cat "${f}")"
    kill -KILL "${p}" 2>/dev/null || true
  done
  pkill -f "${TMP_DIR}/" 2>/dev/null || true
  [[ -n "${KEEP_TMP:-}" ]] || rm -rf "${TMP_DIR}"
}
trap cleanup_tmp EXIT

FAKE_DIR="${TMP_DIR}/fakes"
mkdir -p "${FAKE_DIR}"
export STUB_LOG="${TMP_DIR}/stub_calls.log"
export CALLS_LOG="${TMP_DIR}/fake_calls.log"
export STUB_ENV_LOG="${TMP_DIR}/stub_env.log"
export PATH="${STUB_DIR}:${FAKE_DIR}:${PATH}"

export OCI_COMPARTMENT_ID="ocid1.compartment.oc1..testfake"
export NGC_API_KEY="test-key-not-real"
export POLL_SEC=1 READY_TIMEOUT_SEC=3 WATCHDOG_SEC=600 CLEANUP_RETRY_SEC=2
export TEARDOWN_RETRY_PAUSE_SEC=1 STEP_STOP_WAIT_SEC=5
# Step caps: 60+60+3+60 + scale-up 30 + scale-down 30 = 243 fits WATCHDOG_SEC=600.
export PROVISION_STEP_TIMEOUT_SEC=60 DEPLOY_STEP_TIMEOUT_SEC=60 BENCH_STEP_TIMEOUT_SEC=60
export SCALE_UP_TIMEOUT_SEC=30 SCALE_DOWN_TIMEOUT_SEC=30

mkfake() {  # $1 name, $2 body (after logging the call)
  { echo '#!/bin/bash'; echo "echo \"$1 \$*\" >> \"\${CALLS_LOG}\""; echo "$2"; } > "${FAKE_DIR}/$1"
  chmod +x "${FAKE_DIR}/$1"
}
mkfake fake_preflight 'exit 0'
mkfake fake_iam_check 'exit "${FAKE_IAM_EXIT:-0}"'
mkfake fake_provision '
echo "fake_provision_env AUTOSCALE=${AUTOSCALE:-unset} MAX_GPU_NODES=${MAX_GPU_NODES:-unset} SCALE_DOWN_UNNEEDED=${SCALE_DOWN_UNNEEDED:-unset} SCALE_DOWN_DELAY_AFTER_ADD=${SCALE_DOWN_DELAY_AFTER_ADD:-unset}" >> "${CALLS_LOG}"
printf "AUTOSCALE=%s\nCLUSTER_ID=ocid1.cluster.oc1.phx.fakeclusterid\nNODE_POOL_ID=ocid1.nodepool.oc1.phx.fakepoolid\nSYSTEM_NODE_POOL_ID=ocid1.nodepool.oc1.phx.fakesyspool\nGPU_NODE_SELECTOR=nvidia.com/gpu.present=true\nMAX_GPU_NODES=1\nGPU_SHAPE=VM.GPU.A10.1\nKUBE_CONTEXT=stub-ctx\nREGION=us-phoenix-1\n" "${AUTOSCALE:-0}" > "${NIMBLE_CLUSTER_INFO}"
exit 0'
mkfake fake_deploy 'echo "fake_deploy_env AUTOSCALE=${AUTOSCALE:-unset}" >> "${CALLS_LOG}"; exit 0'
mkfake fake_ready 'exit 0'
mkfake fake_bench '
out=""
while [[ $# -gt 0 ]]; do [[ "$1" == "--out" ]] && out="$2"; shift; done
echo "{\"ok\": true, \"n_ok\": 5, \"ttfr_s\": {\"p50\": 0.1}, \"tokens_per_s\": {\"p50\": 42.0}}" > "${out}"
exit 0'
mkfake fake_teardown 'exit 0'

export RUNNER_PREFLIGHT="${FAKE_DIR}/fake_preflight"
export RUNNER_PROVISION="${FAKE_DIR}/fake_provision"
export RUNNER_DEPLOY="${FAKE_DIR}/fake_deploy"
export RUNNER_READY="${FAKE_DIR}/fake_ready"
export RUNNER_BENCH="${FAKE_DIR}/fake_bench"
export RUNNER_TEARDOWN="${FAKE_DIR}/fake_teardown"
export RUNNER_AUTOSCALER_IAM_CHECK="${FAKE_DIR}/fake_iam_check"

FAIL=0
reset() {  # $1 test id: fresh logs, fresh autoscaler-emulation state
  : > "${STUB_LOG}"; : > "${CALLS_LOG}"; : > "${STUB_ENV_LOG}"
  unset FAKE_IAM_EXIT STUB_AS_SCALEUP STUB_AS_SCALEDOWN STUB_AS_UP_AFTER STUB_AS_DOWN_AFTER \
        MAX_GPU_NODES AUTOSCALE STUB_HELM_OK
  export SCALE_UP_TIMEOUT_SEC=30 SCALE_DOWN_TIMEOUT_SEC=30 STUB_CLUSTER=absent
  export STUB_AS_DIR="${TMP_DIR}/as-$1"
  mkdir -p "${STUB_AS_DIR}"
  export NIMBLE_CLUSTER_INFO="${TMP_DIR}/$1-cluster-info.txt"
}
count() { grep -c "^fake_$1 " "${CALLS_LOG}" 2>/dev/null || true; }
wd_alive() {
  local f="$1/watchdog.pid" p
  [[ -f "${f}" ]] || return 0
  p="$(cat "${f}")"
  for _ in 1 2 3 4 5 6; do kill -0 "${p}" 2>/dev/null || return 0; sleep 1; done
  echo "alive ${p}"
}
wait_for() {  # $1 file, $2 ERE, $3 max seconds
  for _ in $(seq 1 $(( $3 * 5 ))); do grep -qE "$2" "$1" 2>/dev/null && return 0; sleep 0.2; done
  return 1
}
order_of() { grep ' START ' "$1/phases.log" | awk '{print $2}' | tr '\n' ' '; }
report() {  # $1 id, $2 pass(true/false), $3 detail, $4 OUT_DIR
  if [[ "$2" == "true" ]]; then
    echo "$1 PASS  $3"
  else
    echo "$1 FAIL  $3"
    echo "--- phases.log ---"; cat "$4/phases.log" 2>/dev/null || true
    echo "--- runner.log ---"; cat "$4/runner.log" 2>/dev/null || true
    echo "--- trap.log ---"; cat "$4/trap.log" 2>/dev/null || true
    echo "--- watchdog.log ---"; cat "$4/watchdog.log" 2>/dev/null || true
    FAIL=1
  fi
}
receipt_clean() {  # $1 OUT_DIR: no OCID, no IPv4, no dummy key in receipt.md
  python3 - "$1/receipt.md" <<'PY2'
import re, sys
t = open(sys.argv[1], encoding="utf-8").read()
assert "ocid1." not in t and "DUMMYKEY" not in t, "ocid or key in receipt"
assert not re.search(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", t), "IPv4 in receipt"
PY2
}
AS_ORDER="preflight provision deploy scale-up ready bench scale-down teardown verify-clean "

# --- U1: happy path ---
reset U1
O="${TMP_DIR}/outU1"
set +e; NGC_API_KEY="DUMMYKEY-autoscale-1" "${RUNNER}" --autoscale "${O}" > "${TMP_DIR}/u1.out" 2>&1; rc=$?; set -e
order="$(order_of "${O}")"
pass=true
[[ "${rc}" -eq 0 ]] || pass=false
[[ "${order}" == "${AS_ORDER}" ]] || pass=false
[[ "$(count teardown)" -eq 1 && "$(count iam_check)" -eq 1 ]] || pass=false
grep -q '^fake_provision_env AUTOSCALE=1 MAX_GPU_NODES=1 SCALE_DOWN_UNNEEDED=3m SCALE_DOWN_DELAY_AFTER_ADD=3m$' "${CALLS_LOG}" || pass=false
grep -q '^fake_deploy_env AUTOSCALE=1$' "${CALLS_LOG}" || pass=false
python3 - "${O}/summary.json" <<'PY3' || pass=false
import json, sys
s = json.load(open(sys.argv[1]))
a = s["autoscale"]
assert a["result"] == "PASS" and a["reason"] is None, a
for k in ("scale_up_seconds", "pod_ready_seconds", "scale_down_seconds", "gpu_billable_seconds"):
    assert isinstance(a[k], int) and a[k] >= 0, (k, a[k])
assert isinstance(a["gpu_node_minutes"], float), a["gpu_node_minutes"]
assert a["gpu_billing_end"] == "GPU node gone", a["gpu_billing_end"]
assert a["timers"]["scale_down_unneeded"] == "3m" and a["timers"]["scale_down_delay_after_add"] == "3m"
assert a["gpu_node_allocatable"]["nvidia.com/gpu"] == "1" and a["gpu_pool_size_after_scale_down"] == "0"
c = s["cost_split_usd"]
assert all(isinstance(c[k], float) for k in ("gpu", "system_pool", "cluster_fee")), c
assert s["estimated_cost_usd"] is not None and s["bench_ok"] is True
assert s["phase_rc"]["scale-up"] == 0 and s["phase_rc"]["scale-down"] == 0
PY3
grep -q '^- autoscale result: 0→1→0 PASS$' "${O}/receipt.md" || pass=false
for l in '- GPU (USD): ' '- System pool (USD): ' '- Cluster fee (USD): ' '- Scale-up seconds' '- Scale-down seconds' '- Pod Ready seconds'; do
  grep -qF -- "${l}" "${O}/receipt.md" || pass=false
done
receipt_clean "${O}" || pass=false
[[ -z "$(grep -rl DUMMYKEY "${O}" || true)" ]] || pass=false
grep -q 'TriggeredScaleUp' "${O}/scale-up-events.log" || pass=false
grep -q 'ScaleDown' "${O}/scale-down-events.log" || pass=false
grep -q '^kubectl --context stub-ctx scale deployment/nvidia-nim -n default --replicas=0' "${STUB_LOG}" || pass=false
grep -q '^oci ce node-pool get --node-pool-id ocid1.nodepool.oc1.phx.fakepoolid --region us-phoenix-1 ' "${STUB_LOG}" || pass=false
[[ -z "$(wd_alive "${O}")" ]] || pass=false
report U1 "${pass}" "rc=${rc} order=[${order% }] teardown_calls=$(count teardown)" "${O}"
echo "  summary.json autoscale:"
python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); a=s["autoscale"]; print("    " + json.dumps({k: a[k] for k in ("result","scale_up_seconds","pod_ready_seconds","scale_down_seconds","gpu_node_minutes","gpu_billing_end","timers")})); print("    cost_split_usd=" + json.dumps(s["cost_split_usd"]) + " estimated_cost_usd=" + str(s["estimated_cost_usd"]))' "${O}/summary.json"
echo "  receipt.md:"; sed 's/^/    /' "${O}/receipt.md"

# --- U2: no scale-up (NotTriggerScaleUp) ---
reset U2
O="${TMP_DIR}/outU2"
export STUB_AS_SCALEUP=never SCALE_UP_TIMEOUT_SEC=3
set +e; "${RUNNER}" --autoscale "${O}" > "${TMP_DIR}/u2.out" 2>&1; rc=$?; set -e
pass=true
[[ "${rc}" -ne 0 ]] || pass=false
grep -q '^PHASE scale-up END [0-9]* rc=1$' "${O}/phases.log" || pass=false
grep -q "scale-up FAILED: no Ready GPU node matching nvidia.com/gpu.present=true within 3s; NotTriggerScaleUp: pod didn't trigger scale-up: 1 node(s) didn't match" "${O}/runner.log" || pass=false
grep -q "^- autoscale result: 0→1→0 FAIL (scale-up: no Ready GPU node .*NotTriggerScaleUp: pod didn't trigger scale-up" "${O}/receipt.md" || pass=false
[[ "$(count teardown)" -eq 1 && "$(count ready)" -eq 0 && "$(count bench)" -eq 0 ]] || pass=false
[[ -f "${O}/CLEANUP_COMPLETE" ]] || pass=false
receipt_clean "${O}" || pass=false
[[ -z "$(wd_alive "${O}")" ]] || pass=false
report U2 "${pass}" "rc=${rc} teardown_calls=$(count teardown) | $(grep '^- autoscale result' "${O}/receipt.md")" "${O}"

# --- U3: node never leaves on scale-down ---
reset U3
O="${TMP_DIR}/outU3"
export STUB_AS_SCALEDOWN=never SCALE_DOWN_TIMEOUT_SEC=3
set +e; "${RUNNER}" --autoscale "${O}" > "${TMP_DIR}/u3.out" 2>&1; rc=$?; set -e
pass=true
[[ "${rc}" -eq 1 ]] || pass=false
grep -q '^PHASE scale-down END [0-9]* rc=1$' "${O}/phases.log" || pass=false
grep -q '^PHASE verify-clean END [0-9]* rc=0$' "${O}/phases.log" || pass=false
[[ "$(count teardown)" -eq 1 && "$(count bench)" -eq 1 && -f "${O}/CLEANUP_COMPLETE" ]] || pass=false
grep -q '^- autoscale result: 0→1→0 FAIL (scale-down: GPU node still present after 3s' "${O}/receipt.md" || pass=false
python3 -c 'import json,sys; a=json.load(open(sys.argv[1]))["autoscale"]; assert a["scale_up"]["result"]=="PASS" and a["scale_down"]["result"]=="FAIL" and a["gpu_billing_end"]=="teardown confirmed", a' "${O}/summary.json" || pass=false
[[ -z "$(wd_alive "${O}")" ]] || pass=false
report U3 "${pass}" "rc=${rc} teardown_calls=$(count teardown) | $(grep '^- autoscale result' "${O}/receipt.md")" "${O}"

# --- U4: autoscaler IAM check fails in preflight ---
reset U4
O="${TMP_DIR}/outU4"
export FAKE_IAM_EXIT=3
set +e; "${RUNNER}" --autoscale "${O}" > "${TMP_DIR}/u4.out" 2>&1; rc=$?; set -e
pass=true
[[ "${rc}" -eq 1 ]] || pass=false
[[ "$(count provision)" -eq 0 && "$(count teardown)" -eq 0 && "$(count iam_check)" -eq 1 ]] || pass=false
grep -q '^FAIL: autoscaler IAM check exited 3' "${O}/preflight.log" || pass=false
grep -q 'scripts/setup-autoscaler-iam.sh --apply' "${O}/preflight.log" || pass=false
grep -q 'scripts/setup-autoscaler-iam.sh --apply' "${TMP_DIR}/u4.out" || pass=false
[[ ! -f "${O}/watchdog.pid" && -z "$(pgrep -f "watchdog-for .*${O}" || true)" ]] || pass=false
report U4 "${pass}" "rc=${rc} provision_calls=$(count provision) watchdog.pid=$([[ -f "${O}/watchdog.pid" ]] && echo yes || echo no) | $(grep -m1 '^FAIL' "${O}/preflight.log")" "${O}"

# --- U5: SIGTERM during scale-up ---
reset U5
O="${TMP_DIR}/outU5"
export STUB_AS_SCALEUP=never SCALE_UP_TIMEOUT_SEC=60
"${RUNNER}" --autoscale "${O}" > "${TMP_DIR}/u5.out" 2>&1 &
pid=$!
pass=true
wait_for "${O}/phases.log" '^PHASE scale-up START' 30 || pass=false
sleep 1
kill -TERM "${pid}"
set +e; wait "${pid}"; rc=$?; set -e
[[ "${rc}" -eq 143 ]] || pass=false
[[ "$(count teardown)" -eq 1 && "$(count ready)" -eq 0 ]] || pass=false
python3 -c 'import json,sys; a=json.load(open(sys.argv[1]))["autoscale"]; assert a["scale_up"]["reason"].startswith("interrupted (signal TERM)"), a' "${O}/summary.json" || pass=false
[[ -z "$(wd_alive "${O}")" ]] || pass=false
report U5 "${pass}" "rc=${rc} (want 143) teardown_calls=$(count teardown) | $(grep '^- autoscale result' "${O}/receipt.md")" "${O}"

# --- U6: SIGKILL the runner during scale-down -> watchdog tears down ---
reset U6
O="${TMP_DIR}/outU6"
export STUB_AS_SCALEDOWN=never SCALE_DOWN_TIMEOUT_SEC=60
"${RUNNER}" --autoscale "${O}" > "${TMP_DIR}/u6.out" 2>&1 &
pid=$!
pass=true
wait_for "${O}/phases.log" '^PHASE scale-down START' 30 || pass=false
sleep 1
kill -KILL "${pid}"
set +e; wait "${pid}" 2>/dev/null; rc=$?; set -e
wait_for "${O}/watchdog.log" 'WATCHDOG FINAL' 30 || pass=false
tail -1 "${O}/watchdog.log" | grep -q "WATCHDOG FINAL: cleanup completed by watchdog" || pass=false
grep -q "by watchdog" "${O}/CLEANUP_COMPLETE" 2>/dev/null || pass=false
[[ "$(count teardown)" -eq 1 ]] || pass=false
grep -q '^- autoscale result: 0→1→0 FAIL (scale-down: interrupted' "${O}/receipt.md" || pass=false
report U6 "${pass}" "runner rc=${rc} (SIGKILL) teardown_calls=$(count teardown) last=[$(tail -1 "${O}/watchdog.log" | cut -d' ' -f2-)]" "${O}"

# --- U7: MAX_GPU_NODES=2 refused in preflight ---
reset U7
O="${TMP_DIR}/outU7"
set +e; MAX_GPU_NODES=2 "${RUNNER}" --autoscale "${O}" > "${TMP_DIR}/u7.out" 2>&1; rc=$?; set -e
pass=true
[[ "${rc}" -eq 1 && "$(count provision)" -eq 0 && "$(count iam_check)" -eq 0 && ! -f "${O}/watchdog.pid" ]] || pass=false
grep -q '^FAIL: MAX_GPU_NODES=2 is refused' "${O}/preflight.log" || pass=false
report U7 "${pass}" "rc=${rc} provision_calls=$(count provision) | $(grep -m1 '^FAIL' "${O}/preflight.log" | cut -c1-110)" "${O}"

# --- U8: fixed mode regression (no --autoscale; AUTOSCALE=1 left in the shell is ignored) ---
reset U8
O="${TMP_DIR}/outU8"
set +e; AUTOSCALE=1 "${RUNNER}" "${O}" > "${TMP_DIR}/u8.out" 2>&1; rc=$?; set -e
order="$(order_of "${O}")"
pass=true
[[ "${rc}" -eq 0 ]] || pass=false
[[ "${order}" == "preflight provision deploy ready bench teardown verify-clean " ]] || pass=false
grep -q '^fake_provision_env AUTOSCALE=0 ' "${CALLS_LOG}" || pass=false
[[ "$(count iam_check)" -eq 0 ]] || pass=false
! grep -q 'autoscale result' "${O}/receipt.md" || pass=false
grep -q '^- of which system pool (USD): [0-9.]* at 0.074/h$' "${O}/receipt.md" || pass=false
grep -q '^- Estimated cost (USD): [0-9.]*$' "${O}/receipt.md" || pass=false
python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); assert "autoscale" not in s and s["autoscale_mode"] is False and s["system_pool_hourly_usd"]==0.074, s' "${O}/summary.json" || pass=false
! grep -q '^kubectl .*scale deployment' "${STUB_LOG}" || pass=false
report U8 "${pass}" "rc=${rc} order=[${order% }] | $(grep '^- of which system pool' "${O}/receipt.md")" "${O}"

# --- U9: deploy.sh with AUTOSCALE=1 against stubs ---
reset U9
U9HOME="${TMP_DIR}/u9home"; U9BIN="${TMP_DIR}/u9bin"
mkdir -p "${U9HOME}/.oci" "${U9HOME}/.kube" "${U9BIN}"
: > "${U9HOME}/.oci/config"; : > "${U9HOME}/.kube/config"
# curl stub: prereqs' NGC model-access probe must not reach the network.
printf '#!/bin/bash\necho "curl $*" >> "${STUB_LOG}"\nprintf 000\n' > "${U9BIN}/curl"; chmod +x "${U9BIN}/curl"
printf 'AUTOSCALE=1\nKUBE_CONTEXT=stub-ctx\n' > "${NIMBLE_CLUSTER_INFO}"
U9KEY="nvapi-DUMMYKEY-u9-$$"
set +e
HOME="${U9HOME}" PATH="${STUB_DIR}:${U9BIN}:${PATH}" STUB_HELM_OK=1 STUB_CLUSTER=present \
  NGC_API_KEY="${U9KEY}" CONFIRM_COST=yes AUTOSCALE=1 \
  bash "${REPO_ROOT}/scripts/deploy.sh" > "${TMP_DIR}/u9.out" 2>&1
rc=$?
set -e
inst="$(grep '^helm upgrade --install' "${STUB_LOG}" | grep -v -- '--dry-run' || true)"
pass=true
[[ "${rc}" -eq 0 ]] || pass=false
[[ -n "${inst}" && "${inst}" != *"--wait"* && "${inst}" == *" -f - "* ]] || pass=false
grep -q 'GPU availability: skipped (autoscale: GPU pool starts at 0)' "${TMP_DIR}/u9.out" || pass=false
grep -q 'GPU nodes: skipped (autoscale: GPU pool starts at 0)' "${TMP_DIR}/u9.out" || pass=false
grep -q 'NVIDIA GPU allocatable: skipped (autoscale: GPU pool starts at 0)' "${TMP_DIR}/u9.out" || pass=false
[[ "$(grep -c 'helm-stdin bytes=[0-9]* apiKey_line=yes' "${STUB_LOG}")" -ge 2 ]] || pass=false
[[ -z "$(grep -l -e "${U9KEY}" "${STUB_LOG}" "${TMP_DIR}/u9.out" || true)" ]] || pass=false
grep -q '^kubectl --context stub-ctx .*get pods -n default -l app.kubernetes.io/instance=nvidia-nim --no-headers' "${STUB_LOG}" || pass=false
! grep -q 'kubectl .*wait --for=condition=ready' "${STUB_LOG}" || pass=false
! grep -q '^curl .*'"${U9KEY}" "${STUB_LOG}" || pass=false
report U9 "${pass}" "rc=${rc} install=[${inst}] stdin=[$(grep 'helm-stdin' "${STUB_LOG}" | tail -1)] key_in_argv_or_output=$(grep -c -e "${U9KEY}" "${STUB_LOG}" "${TMP_DIR}/u9.out" | tr '\n' ' ')" "${TMP_DIR}"
[[ "${pass}" == "true" ]] || { echo "--- u9.out ---"; tail -40 "${TMP_DIR}/u9.out"; }

# --- PC: pane_close_check.sh --autoscale, pane close simulated (INT+HUP, then KILL to the group) ---
reset PC
pass=true
set -m
TMPDIR="${TMP_DIR}" bash "${REPO_ROOT}/tests/pane_close_check.sh" --autoscale > "${TMP_DIR}/pc.out" 2>&1 &
pid=$!
set +m
wait_for "${TMP_DIR}/pc.out" '^Logs to inspect afterwards: ' 10 || pass=false
PCO="$(sed -n 's/^Logs to inspect afterwards: //p' "${TMP_DIR}/pc.out")"
wait_for "${PCO}/phases.log" '^PHASE scale-up START' 30 || pass=false
sleep 1
kill -INT -- "-${pid}" 2>/dev/null || true
kill -HUP -- "-${pid}" 2>/dev/null || true
sleep 1
kill -KILL -- "-${pid}" 2>/dev/null || true
set +e; wait "${pid}" 2>/dev/null; rc=$?; set -e
wait_for "${PCO}/watchdog.log" 'WATCHDOG FINAL' 40 || pass=false
set +e; bash "${REPO_ROOT}/tests/pane_close_check.sh" --inspect "${PCO}" > "${TMP_DIR}/pc-inspect.out" 2>&1; irc=$?; set -e
[[ "${irc}" -eq 0 ]] || pass=false
grep -q '^PANE CLOSE CHECK: PASS$' "${TMP_DIR}/pc-inspect.out" || pass=false
grep -q 'by watchdog' "${PCO}/CLEANUP_COMPLETE" 2>/dev/null || pass=false
grep -q '^PHASE scale-up START' "${PCO}/phases.log" || pass=false
report PC "${pass}" "autoscale pane close: runner rc=${rc} inspect rc=${irc} marker=[$(cat "${PCO}/CLEANUP_COMPLETE" 2>/dev/null)]" "${PCO}"
sed 's/^/    /' "${TMP_DIR}/pc-inspect.out"

if [[ "${FAIL}" -ne 0 ]]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: all passed"
