#!/bin/bash
# Pane-close check for scripts/run_measured.sh. Stub-only: every RUNNER_*
# hook is a harmless sleep-based fake and tests/stubs/ (fake oci, kubectl,
# helm) is first on PATH. No cloud call, no cost.
#
#   tests/pane_close_check.sh              run it in a real terminal pane, then
#                                          close the pane when told to (fixed mode:
#                                          close during the fake deploy)
#   tests/pane_close_check.sh --autoscale  same for the --autoscale runner: close
#                                          during the scale-up phase (stub kubectl
#                                          never shows a GPU node)
#   tests/pane_close_check.sh --inspect DIR  afterwards (in a new pane): PASS/FAIL
#   tests/pane_close_check.sh --help       this text
# tests/run_measured_autoscale_test.sh (PC) runs the --autoscale variant
# non-interactively: HUP+INT then KILL to its process group, then --inspect.
#
# Expected: the runner's trap or, if the terminal kills it outright, the
# out-of-tree watchdog finishes the fake teardown; watchdog.log ends with
# "WATCHDOG FINAL: cleanup completed ..." and DIR/CLEANUP_COMPLETE names
# who completed it.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
fi
AS=0
if [[ "${1:-}" == "--autoscale" ]]; then AS=1; shift; fi

if [[ "${1:-}" == "--inspect" ]]; then
  D="${2:?usage: tests/pane_close_check.sh --inspect OUT_DIR}"
  ok=true
  last="$(tail -1 "${D}/watchdog.log" 2>/dev/null || true)"
  echo "watchdog.log last line: ${last:-<missing>}"
  echo "CLEANUP_COMPLETE:       $(cat "${D}/CLEANUP_COMPLETE" 2>/dev/null || echo '<missing>')"
  echo "fake teardown calls:    $(grep -c '^fake_teardown' "${D}/../calls.log" 2>/dev/null || true)"
  echo "phases.log:"; sed 's/^/  /' "${D}/phases.log" 2>/dev/null || true
  left="$(pgrep -fl "run_measured.*${D}" || true)"
  echo "processes still running for this dir: ${left:-none}"
  if [[ "${last}" == *"nothing billable was started"* ]]; then
    echo "PANE CLOSE CHECK: INCONCLUSIVE (pane closed before the fake provision started; re-run and wait for 'PHASE deploy START' or 'PHASE scale-up START')"
    exit 2
  fi
  [[ "${last}" == *"WATCHDOG FINAL: cleanup completed"* ]] || ok=false
  [[ -f "${D}/CLEANUP_COMPLETE" ]] || ok=false
  [[ -z "${left}" ]] || ok=false
  if [[ "${ok}" == "true" ]]; then echo "PANE CLOSE CHECK: PASS"; exit 0; fi
  echo "PANE CLOSE CHECK: FAIL"; exit 1
fi

BASE="$(mktemp -d "${TMPDIR:-/tmp}/pane-close-check.XXXXXX")"
OUT="${BASE}/out"
FAKES="${BASE}/fakes"
mkdir -p "${FAKES}"
export CALLS_LOG="${BASE}/calls.log"
export STUB_LOG="${BASE}/stub_calls.log"
for f in preflight provision deploy ready bench teardown iam_check; do
  case "${f}" in
    provision)
      if [[ "${AS}" == "1" ]]; then
        body='printf "AUTOSCALE=1\nCLUSTER_ID=ocid1.cluster.oc1..pane\nNODE_POOL_ID=ocid1.nodepool.oc1..pane\nSYSTEM_NODE_POOL_ID=ocid1.nodepool.oc1..panesys\nGPU_NODE_SELECTOR=nvidia.com/gpu.present=true\nMAX_GPU_NODES=1\n" > "${NIMBLE_CLUSTER_INFO}"; sleep 2'
      else
        body='sleep 2'
      fi ;;
    deploy)    if [[ "${AS}" == "1" ]]; then body='sleep 1'; else body='sleep 900'; fi ;;
    teardown)  body='sleep 5' ;;
    bench)     body='out=""; while [[ $# -gt 0 ]]; do [[ "$1" == "--out" ]] && out="$2"; shift; done; echo "{\"ok\": true}" > "${out}"' ;;
    *)         body=':' ;;
  esac
  printf '#!/bin/bash\necho "fake_%s $*" >> "${CALLS_LOG}"\n%s\nexit 0\n' "${f}" "${body}" > "${FAKES}/fake_${f}"
  chmod +x "${FAKES}/fake_${f}"
done

export PATH="${REPO_ROOT}/tests/stubs:${PATH}"
export STUB_CLUSTER=absent
export OCI_COMPARTMENT_ID="ocid1.compartment.oc1..pane-check-fake"
export NGC_API_KEY="PANECHECK-DUMMY-KEY"
export RUNNER_PREFLIGHT="${FAKES}/fake_preflight"
export RUNNER_PROVISION="${FAKES}/fake_provision"
export RUNNER_DEPLOY="${FAKES}/fake_deploy"
export RUNNER_READY="${FAKES}/fake_ready"
export RUNNER_BENCH="${FAKES}/fake_bench"
export RUNNER_TEARDOWN="${FAKES}/fake_teardown"
export POLL_SEC=1 WATCHDOG_SEC=1200 CLEANUP_RETRY_SEC=10 TEARDOWN_RETRY_PAUSE_SEC=2 STEP_STOP_WAIT_SEC=10
# Step caps that fit WATCHDOG_SEC=1200 (the watchdog-budget preflight):
#   fixed 60 + 1000 + 30 + 60 = 1150; --autoscale 60 + 60 + 30 + 60 + 900 + 60 = 1170
if [[ "${AS}" == "1" ]]; then
  export PROVISION_STEP_TIMEOUT_SEC=60 DEPLOY_STEP_TIMEOUT_SEC=60 READY_TIMEOUT_SEC=30 \
         BENCH_STEP_TIMEOUT_SEC=60 SCALE_UP_TIMEOUT_SEC=900 SCALE_DOWN_TIMEOUT_SEC=60
  export RUNNER_AUTOSCALER_IAM_CHECK="${FAKES}/fake_iam_check"
  export NIMBLE_CLUSTER_INFO="${BASE}/cluster-info.txt"
  export STUB_AS_DIR="${BASE}/as" STUB_AS_SCALEUP=never
  mkdir -p "${STUB_AS_DIR}"
  RUN_ARGS=(--autoscale)
  WHEN="'PHASE scale-up START' appears below (the stub never shows a GPU node; scale-up waits 15 min)"
else
  export PROVISION_STEP_TIMEOUT_SEC=60 DEPLOY_STEP_TIMEOUT_SEC=1000 READY_TIMEOUT_SEC=30 \
         BENCH_STEP_TIMEOUT_SEC=60
  RUN_ARGS=()
  WHEN="'PHASE deploy START' appears below (the fake deploy sleeps 15 min)"
fi

echo "Logs to inspect afterwards: ${OUT}"
echo "  then run: ${REPO_ROOT}/tests/pane_close_check.sh --inspect ${OUT}"
echo "Stub-only run: fake hooks, fake oci/kubectl/helm, no cloud call, no cost."
echo ">>> CLOSE THIS TERMINAL PANE NOW, once ${WHEN}. <<<"
exec "${REPO_ROOT}/scripts/run_measured.sh" ${RUN_ARGS[@]+"${RUN_ARGS[@]}"} "${OUT}"
