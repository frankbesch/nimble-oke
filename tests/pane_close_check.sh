#!/bin/bash
# Pane-close check for scripts/run_measured.sh. Stub-only: every RUNNER_*
# hook is a harmless sleep-based fake and tests/stubs/ (fake oci, kubectl,
# helm) is first on PATH. No cloud call, no cost.
#
#   tests/pane_close_check.sh              run it in a real terminal pane, then
#                                          close the pane when told to
#   tests/pane_close_check.sh --inspect DIR  afterwards (in a new pane): PASS/FAIL
#
# Expected: the runner's trap or, if the terminal kills it outright, the
# out-of-tree watchdog finishes the fake teardown; watchdog.log ends with
# "WATCHDOG FINAL: cleanup completed ..." and DIR/CLEANUP_COMPLETE names
# who completed it.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
    echo "PANE CLOSE CHECK: INCONCLUSIVE (pane closed before the fake provision started; re-run and wait for 'PHASE deploy START')"
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
for f in preflight provision deploy ready bench teardown; do
  case "${f}" in
    provision) body='sleep 2' ;;
    deploy)    body='sleep 900' ;;
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

echo "Logs to inspect afterwards: ${OUT}"
echo "  then run: ${REPO_ROOT}/tests/pane_close_check.sh --inspect ${OUT}"
echo "Stub-only run: fake hooks, fake oci/kubectl/helm, no cloud call, no cost."
echo ">>> CLOSE THIS TERMINAL PANE NOW, once 'PHASE deploy START' appears below (the fake deploy sleeps 15 min). <<<"
exec "${REPO_ROOT}/scripts/run_measured.sh" "${OUT}"
