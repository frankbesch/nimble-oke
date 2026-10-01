#!/bin/bash
# Tests for scripts/run_measured.sh (and scripts/bench.py). Stubs only: no
# real oci/kubectl/helm and no cloud call. tests/stubs/ is first on PATH and
# every RUNNER_* hook points at a fake in a temp dir that logs its calls.
#   R1 success path    R2 deploy fails    R3 ready never arrives
#   R8 preflight fails R9 NGC key never in OUT_DIR files or child argv
#   D1/D2 preflight detectors vs fixtures   R12 --preflight-only
#   B1 bench.py against a local stub NIM server (127.0.0.1 only)
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

mkfake() {  # $1 name, $2 body (after logging the call)
  { echo '#!/bin/bash'; echo "echo \"$1 \$*\" >> \"\${CALLS_LOG}\""; echo "$2"; } > "${FAKE_DIR}/$1"
  chmod +x "${FAKE_DIR}/$1"
}
mkfake fake_preflight 'exit "${FAKE_PREFLIGHT_EXIT:-0}"'
mkfake fake_provision 'sleep "${FAKE_PROVISION_SLEEP:-0}"; exit "${FAKE_PROVISION_EXIT:-0}"'
cat > "${FAKE_DIR}/fake_deploy" <<'EOF2'
#!/bin/bash
echo "fake_deploy $*" >> "${CALLS_LOG}"
if [[ -n "${FAKE_DEPLOY_LEAK:-}" ]]; then
  # Print the key four ways, as deploy.sh's helm --dry-run would render it.
  dcj='{"auths":{"nvcr.io":{"username":"$oauthtoken","password":"'"${NGC_API_KEY}"'"}}}'
  echo "plain: ${NGC_API_KEY}"
  echo "  NGC_API_KEY: $(printf %s "${NGC_API_KEY}" | base64)"
  echo "  .dockerconfigjson: $(printf %s "${dcj}" | base64 | tr -d '\n')"
  echo "stderr copy: ${NGC_API_KEY}" >&2
fi
sleep "${FAKE_DEPLOY_SLEEP:-0}"
exit "${FAKE_DEPLOY_EXIT:-0}"
EOF2
chmod +x "${FAKE_DIR}/fake_deploy"
mkfake fake_ready 'exit "${FAKE_READY_EXIT:-0}"'
mkfake fake_bench '
out=""
while [[ $# -gt 0 ]]; do [[ "$1" == "--out" ]] && out="$2"; shift; done
[[ -n "${out}" ]] && echo "{\"ok\": true, \"n_ok\": 5, \"ttfr_s\": {\"p50\": 0.1}, \"tokens_per_s\": {\"p50\": 42.0}}" > "${out}"
exit "${FAKE_BENCH_EXIT:-0}"'
mkfake fake_teardown 'exit "${FAKE_TEARDOWN_EXIT:-0}"'

export RUNNER_PREFLIGHT="${FAKE_DIR}/fake_preflight"
export RUNNER_PROVISION="${FAKE_DIR}/fake_provision"
export RUNNER_DEPLOY="${FAKE_DIR}/fake_deploy"
export RUNNER_READY="${FAKE_DIR}/fake_ready"
export RUNNER_BENCH="${FAKE_DIR}/fake_bench"
export RUNNER_TEARDOWN="${FAKE_DIR}/fake_teardown"

FAIL=0
reset() {
  : > "${STUB_LOG}"; : > "${CALLS_LOG}"
  unset FAKE_PREFLIGHT_EXIT FAKE_PROVISION_SLEEP FAKE_PROVISION_EXIT FAKE_DEPLOY_LEAK \
        FAKE_DEPLOY_SLEEP FAKE_DEPLOY_EXIT FAKE_READY_EXIT FAKE_BENCH_EXIT FAKE_TEARDOWN_EXIT
  export STUB_CLUSTER=absent
}
count() { grep -c "^fake_$1" "${CALLS_LOG}" 2>/dev/null || true; }
wd_alive() {  # echoes "alive <pid>" if OUT_DIR's watchdog still runs (after a grace wait)
  local f="$1/watchdog.pid" p
  [[ -f "${f}" ]] || return 0
  p="$(cat "${f}")"
  for _ in 1 2 3 4 5 6; do kill -0 "${p}" 2>/dev/null || return 0; sleep 1; done
  echo "alive ${p}"
}
report() {  # $1 id, $2 pass(true/false), $3 detail, $4 OUT_DIR
  if [[ "$2" == "true" ]]; then
    echo "$1 PASS  $3"
  else
    echo "$1 FAIL  $3"
    echo "--- phases.log ---"; cat "$4/phases.log" 2>/dev/null || true
    echo "--- trap.log ---"; cat "$4/trap.log" 2>/dev/null || true
    FAIL=1
  fi
}

# --- R1: success path ---
reset
O="${TMP_DIR}/outR1"
set +e; "${RUNNER}" "${O}" > "${TMP_DIR}/r1.out" 2>&1; rc=$?; set -e
pass=true
[[ "${rc}" -eq 0 ]] || pass=false
[[ "$(count teardown)" -eq 1 ]] || pass=false
order="$(grep ' START ' "${O}/phases.log" | awk '{print $2}' | tr '\n' ' ')"
[[ "${order}" == "preflight provision deploy ready bench teardown verify-clean " ]] || pass=false
python3 -m json.tool "${O}/summary.json" > /dev/null || pass=false
[[ -z "$(wd_alive "${O}")" ]] || pass=false
tail -1 "${O}/watchdog.log" | grep -q "WATCHDOG FINAL: cleanup completed" || pass=false
report R1 "${pass}" "rc=${rc} teardown_calls=$(count teardown) order=[${order% }]" "${O}"
echo "  phases.log:"; sed 's/^/    /' "${O}/phases.log"
echo "  summary.json (excerpt):"
python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); print("    " + json.dumps({k: s[k] for k in ("live_run","runner_exit_code","shape","region","image","k8s_version","phase_seconds","billable_seconds","estimated_cost_usd","bench_ok","teardown")}))' "${O}/summary.json"
echo "  watchdog.log last line: $(tail -1 "${O}/watchdog.log")"

# --- R2: deploy hook fails ---
reset
O="${TMP_DIR}/outR2"
export FAKE_DEPLOY_EXIT=1
set +e; "${RUNNER}" "${O}" > "${TMP_DIR}/r2.out" 2>&1; rc=$?; set -e
pass=true
[[ "${rc}" -ne 0 ]] || pass=false
[[ "$(count teardown)" -eq 1 ]] || pass=false
[[ "$(count bench)" -eq 0 ]] || pass=false
[[ -z "$(wd_alive "${O}")" ]] || pass=false
report R2 "${pass}" "rc=${rc} teardown_calls=$(count teardown) bench_calls=$(count bench)" "${O}"

# --- R3: ready never arrives ---
reset
O="${TMP_DIR}/outR3"
export FAKE_READY_EXIT=1
t0=$(date +%s)
set +e; "${RUNNER}" "${O}" > "${TMP_DIR}/r3.out" 2>&1; rc=$?; set -e
pass=true
[[ "${rc}" -ne 0 ]] || pass=false
grep -q "ready TIMEOUT" "${O}/runner.log" || pass=false
grep -q "^PHASE ready END [0-9]* rc=1$" "${O}/phases.log" || pass=false
[[ "$(count teardown)" -eq 1 ]] || pass=false
[[ "$(count bench)" -eq 0 ]] || pass=false
[[ -z "$(wd_alive "${O}")" ]] || pass=false
report R3 "${pass}" "rc=${rc} ready_probes=$(count ready) teardown_calls=$(count teardown) elapsed=$(( $(date +%s) - t0 ))s ($(grep -h 'ready TIMEOUT' "${O}/runner.log" | cut -d' ' -f2-))" "${O}"

# --- R8: preflight fails ---
reset
O="${TMP_DIR}/outR8"
export FAKE_PREFLIGHT_EXIT=1
set +e; "${RUNNER}" "${O}" > "${TMP_DIR}/r8.out" 2>&1; rc=$?; set -e
pass=true
[[ "${rc}" -ne 0 ]] || pass=false
[[ "$(count provision)" -eq 0 ]] || pass=false
[[ "$(count teardown)" -eq 0 ]] || pass=false
[[ ! -f "${O}/watchdog.pid" ]] || pass=false
wdprocs="$(pgrep -f "watchdog-for .*${O}" || true)"
[[ -z "${wdprocs}" ]] || pass=false
report R8 "${pass}" "rc=${rc} provision_calls=$(count provision) watchdog.pid_exists=$([[ -f "${O}/watchdog.pid" ]] && echo yes || echo no) watchdog_procs=[${wdprocs}]" "${O}"

# --- R9: NGC key never in OUT_DIR files or in any process argv ---
reset
O="${TMP_DIR}/outR9"
export NGC_API_KEY="DUMMYKEY-123456"
export FAKE_DEPLOY_LEAK=1 FAKE_DEPLOY_SLEEP=3
PS_LOG="${TMP_DIR}/ps_samples.txt"
: > "${PS_LOG}"
"${RUNNER}" "${O}" > "${TMP_DIR}/r9.out" 2>&1 &
r9=$!
samples=0
while kill -0 "${r9}" 2>/dev/null; do
  ps -A -ww -o pid= -o command= >> "${PS_LOG}" 2>/dev/null || true
  samples=$((samples + 1))
  sleep 0.2
done
set +e; wait "${r9}"; rc=$?; set -e
export NGC_API_KEY="test-key-not-real"
key_b64="$(printf %s DUMMYKEY-123456 | base64)"
file_hits="$(grep -rl -e DUMMYKEY -e "${key_b64}" "${O}" || true)"
argv_hits="$(grep -c DUMMYKEY "${PS_LOG}" || true)"
saw_deploy="$(grep -c 'fake_deploy' "${PS_LOG}" || true)"
saw_watchdog="$(grep -c 'watchdog-for' "${PS_LOG}" || true)"
redacted="$(grep -c 'REDACTED' "${O}/deploy.log" || true)"
leak_ran="$(count deploy)"
pass=true
[[ "${rc}" -eq 0 ]] || pass=false
[[ -z "${file_hits}" ]] || pass=false
[[ "${argv_hits}" -eq 0 ]] || pass=false
[[ "${saw_deploy}" -gt 0 && "${saw_watchdog}" -gt 0 ]] || pass=false
[[ "${redacted}" -ge 4 && "${leak_ran}" -eq 1 ]] || pass=false
report R9 "${pass}" "rc=${rc} files_with_key=[${file_hits}] ps_samples=${samples} argv_lines_with_key=${argv_hits} sampled_fake_deploy_lines=${saw_deploy} sampled_watchdog_lines=${saw_watchdog} redacted_lines_in_deploy.log=${redacted}" "${O}"
echo "  deploy.log (the fake printed the key 4 ways):"; sed 's/^/    /' "${O}/deploy.log"

# --- D1 / D2: the preflight DETECTORS, tested against fixtures with
# --preflight-only and the DEFAULT preflight (no RUNNER_PREFLIGHT). Fixtures
# are scratch copies of scripts/oke-optimized-config.sh passed through the
# RUNNER_OKE_CONFIG test hook:
#   D1a shape override injected      -> preflight fails with the shape message
#   D2a AD log line on stdout injected -> preflight fails with the AD message
#   D1b/D2b the real repo config     -> both checks print "ok:"; whole preflight rc 0
# Every case: provision never called, no watchdog.
REAL_CFG="${REPO_ROOT}/scripts/oke-optimized-config.sh"
FIX_SHAPE="${TMP_DIR}/fixture-shape-override.sh"
FIX_AD="${TMP_DIR}/fixture-ad-stdout.sh"
sed 's/^readonly OKE_GPU_SHAPE=.*/readonly OKE_GPU_SHAPE="VM.GPU.A10.2"  # injected defect/' "${REAL_CFG}" > "${FIX_SHAPE}"
cp "${REAL_CFG}" "${FIX_AD}"
cat >> "${FIX_AD}" <<'FIX'
# injected defect: a log line on stdout, as before the fix
get_oke_availability_domain() {
    echo "[NIM-OKE][INFO] Getting availability domain for ${2:-unknown}"
    echo "Stub:PHX-AD-1"
}
FIX
pf_only_default() {  # $1 OUT_DIR, $2 config path; runs default preflight, prints rc
  local rc=0
  env -u RUNNER_PREFLIGHT -u NGC_API_KEY RUNNER_OKE_CONFIG="$2" OKE_GPU_SHAPE=VM.GPU.A10.1 \
    "${RUNNER}" --preflight-only "$1" > "$1.out" 2>&1 || rc=$?
  echo "${rc}"
}
no_side_effects() {  # $1 OUT_DIR: true if nothing past preflight ran
  [[ "$(count provision)" -eq 0 && "$(count deploy)" -eq 0 && "$(count teardown)" -eq 0 ]] || return 1
  [[ ! -f "$1/watchdog.pid" ]] || return 1
  [[ -z "$(pgrep -f "watchdog-for .*$1" || true)" ]]
}

reset
O="${TMP_DIR}/outD1a"
pre=true; grep -q '^readonly OKE_GPU_SHAPE="VM.GPU.A10.2"  # injected defect' "${FIX_SHAPE}" || pre=false
rc="$(pf_only_default "${O}" "${FIX_SHAPE}")"
pass="${pre}"
[[ "${rc}" -ne 0 ]] || pass=false
grep -q "^FAIL: provision-cluster.sh would create shape 'VM.GPU.A10.2', not the requested 'VM.GPU.A10.1'" "${O}/preflight.log" || pass=false
no_side_effects "${O}" || pass=false
report D1a "${pass}" "fixture_injected=${pre} rc=${rc} provision_calls=$(count provision) | $(grep -m1 '^FAIL' "${O}/preflight.log")" "${O}"

reset
O="${TMP_DIR}/outD2a"
pre=true; grep -q '^    echo "\[NIM-OKE\]\[INFO\] Getting availability domain for ${2:-unknown}"$' "${FIX_AD}" || pre=false
rc="$(pf_only_default "${O}" "${FIX_AD}")"
pass="${pre}"
[[ "${rc}" -ne 0 ]] || pass=false
grep -q "^ok: provision-cluster.sh would create the requested shape" "${O}/preflight.log" || pass=false
grep -q "^FAIL: get_oke_availability_domain prints log lines on stdout" "${O}/preflight.log" || pass=false
no_side_effects "${O}" || pass=false
report D2a "${pass}" "fixture_injected=${pre} rc=${rc} provision_calls=$(count provision) | $(grep -m1 '^FAIL' "${O}/preflight.log")" "${O}"

reset
O="${TMP_DIR}/outDreal"
rc="$(pf_only_default "${O}" "${REAL_CFG}")"
nofail=true; ! grep -q '^FAIL' "${O}/preflight.log" || nofail=false
pass=true
grep -q "^ok: provision-cluster.sh would create the requested shape" "${O}/preflight.log" || pass=false
! grep -q "would create shape" "${O}/preflight.log" || pass=false
no_side_effects "${O}" || pass=false
report D1b "${pass}" "real config: $(grep '^ok: provision-cluster.sh' "${O}/preflight.log")" "${O}"
pass=true
grep -q "^ok: availability-domain helper returns one line" "${O}/preflight.log" || pass=false
[[ "${rc}" -eq 0 && "${nofail}" == "true" ]] || pass=false
grep -q "^SKIPPED: NGC_API_KEY check" "${O}/preflight.log" || pass=false
grep -q "^preflight checks passed" "${O}/preflight.log" || pass=false
no_side_effects "${O}" || pass=false
report D2b "${pass}" "real config: rc=${rc} $(grep '^ok: availability-domain' "${O}/preflight.log"); $(grep '^SKIPPED' "${O}/preflight.log")" "${O}"
echo "  preflight.log (real config, stubbed oci):"; sed 's/^/    /' "${O}/preflight.log"

# --- R12: --preflight-only with the hook: rc mirrors preflight; no provision, no watchdog; NGC key not required ---
pf_only_hook_test() {  # $1 id, $2 fake preflight exit code
  reset
  local O="${TMP_DIR}/out$1" rc=0 pass=true
  FAKE_PREFLIGHT_EXIT="$2" env -u NGC_API_KEY "${RUNNER}" --preflight-only "${O}" > "${O}.out" 2>&1 || rc=$?
  [[ "${rc}" -eq "$2" ]] || pass=false
  [[ "$(count preflight)" -eq 1 ]] || pass=false
  no_side_effects "${O}" || pass=false
  [[ -f "${O}/preflight.log" ]] || pass=false
  [[ "$(awk '{print $2" "$3}' "${O}/phases.log" | tr '\n' ',')" == "preflight START,preflight END," ]] || pass=false
  grep -q "^PHASE preflight END [0-9]* rc=$2$" "${O}/phases.log" || pass=false
  report "$1" "${pass}" "preflight_exit=$2 rc=${rc} preflight_calls=$(count preflight) provision_calls=$(count provision) watchdog.pid=$([[ -f "${O}/watchdog.pid" ]] && echo yes || echo no) files=[$(ls -A "${O}" | tr '\n' ' ')]" "${O}"
}
pf_only_hook_test R12a 0
pf_only_hook_test R12b 3

# --- B1: bench.py against a local stub NIM (127.0.0.1, ephemeral port) ---
PORT_FILE="${TMP_DIR}/port"
python3 - "${PORT_FILE}" > "${TMP_DIR}/stubnim.log" 2>&1 <<'PY' &
import json, sys, http.server
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, obj):
        b = json.dumps(obj).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        self._send({"data": [{"id": "meta/llama3-8b-instruct"}]})
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self._send({"choices": [{"message": {"content": "stub reply"}}],
                    "usage": {"prompt_tokens": 10, "completion_tokens": 20}})
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(s.server_address[1]))
s.serve_forever()
PY
srv=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -s "${PORT_FILE}" ]] && break; sleep 0.3; done
set +e
NGC_API_KEY=DUMMYKEY-123456 python3 "${REPO_ROOT}/scripts/bench.py" --url "http://127.0.0.1:$(cat "${PORT_FILE}")" \
  --n 3 --out "${TMP_DIR}/b1.json" > "${TMP_DIR}/b1.out" 2>&1
brc=$?
set -e
kill "${srv}" 2>/dev/null || true; wait "${srv}" 2>/dev/null || true
pass=true
[[ "${brc}" -eq 0 ]] || pass=false
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["ok"] and d["n_ok"]==3 and d["tokens_per_s"]["p50"]>0 and "p50" in d["ttfr_s"]' "${TMP_DIR}/b1.json" || pass=false
! grep -q DUMMYKEY "${TMP_DIR}/b1.json" "${TMP_DIR}/b1.out" || pass=false
report B1 "${pass}" "rc=${brc} $(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("model=%s n_ok=%s ttfr_s=%s tokens_per_s=%s" % (d["model"], d["n_ok"], d["ttfr_s"], d["tokens_per_s"]))' "${TMP_DIR}/b1.json")" "${TMP_DIR}"

if [[ "${FAIL}" -ne 0 ]]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: all passed"
