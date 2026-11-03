#!/bin/bash
# Tests for scripts/run_measured.sh (and scripts/bench.py). Stubs only: no
# real oci/kubectl/helm and no cloud call. tests/stubs/ is first on PATH and
# every RUNNER_* hook points at a fake in a temp dir that logs its calls.
#   R1 success path    R2 deploy fails    R3 ready never arrives
#   R8 preflight fails R9 NGC key never in OUT_DIR files or child argv
#   D1/D2 preflight detectors vs fixtures   R12 --preflight-only
#   B1 bench.py against a local stub NIM server (127.0.0.1 only)
#   R1 also: receipt.md (no OCIDs/IPs) and kube context pinning
#   R13 busy NIM_LOCAL_PORT -> free port, passed to bench   R14 port-forward dies -> fast fail
#   P1 bc / curl missing -> preflight FAIL   D3 pinned Kubernetes version not offered
#   R15 --key-file (mode 644 refused, 600 accepted, key never in files/argv)
#   R16 the runner's own oci calls target OCI_REGION (OCI_CLI_REGION exported)
#   R17 WATCHDOG_SEC below the step-budget sum -> preflight fails (ALLOW_SHORT_WATCHDOG=yes proceeds)
#   R18 a step past its hard timeout is stopped and teardown runs
# Keyless path and Keychain key source (docs/key-path.md). Every key is an
# obviously fake placeholder; `security` is stubbed (tests/stubs/security):
#   K1 --key-keychain: runner never reads the key; deploy gets KEYLESS=1 and the
#      service name; the helper pipes the key into the (stub) Secret store;
#      leak grep: stdout, stderr, OUT_DIR (receipt, summary, logs), stub logs, argv
#   K2 Keychain item missing -> preflight fails, nothing created
#   K3 --key-keychain with --key-file / --autoscale -> usage error, nothing created
#   K4 deploy.sh KEYLESS=1 end to end on stubs: Secrets made outside Helm, Helm
#      stdin never carries a key, pre-stage then API Secret deleted then serve;
#      leak grep on stdout/stderr and stub logs
#   K5 deploy.sh KEYLESS=1 failures: pre-stage fails -> both Secrets removed;
#      Deployment still has NGC_API_KEY -> keyless check fails; an existing
#      release -> refused before any Secret is made
#   K6 ngc-secrets.sh sources: --key-file (600 ok, 644 refused), env fallback,
#      empty Keychain value refused and no Secret left; leak grep
#   K8 keyless-check phase (evidence for gates 1 and 2 before bench):
#      runtime env holds the key -> FAIL, no bench, teardown; API Secret left ->
#      FAIL; exec unavailable -> PASS on pod spec; key in Helm values -> FAIL
#      and the key never reaches OUT_DIR; keyless budget defaults
#   K7 helm template (real helm, if installed): keyless serve renders no
#      NGC_API_KEY env and no Secret; the fake key never reaches a rendered
#      manifest; keyless + ngc.apiKey refuses to render; the pre-stage Job
#      mounts the cache PVC at the chart path and at /opt/nim/.cache
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="${REPO_ROOT}/scripts/run_measured.sh"
STUB_DIR="${REPO_ROOT}/tests/stubs"

# Real helm (for K7) before the stubs shadow it on PATH; empty if not installed.
REAL_HELM="$(command -v helm 2>/dev/null || true)"

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
# Step caps short enough that their sum (60+60+3+60 = 183) fits WATCHDOG_SEC=600.
export PROVISION_STEP_TIMEOUT_SEC=60 DEPLOY_STEP_TIMEOUT_SEC=60 BENCH_STEP_TIMEOUT_SEC=60
export STUB_ENV_LOG="${TMP_DIR}/stub_env.log"

mkfake() {  # $1 name, $2 body (after logging the call)
  { echo '#!/bin/bash'; echo "echo \"$1 \$*\" >> \"\${CALLS_LOG}\""; echo "$2"; } > "${FAKE_DIR}/$1"
  chmod +x "${FAKE_DIR}/$1"
}
mkfake fake_preflight 'exit "${FAKE_PREFLIGHT_EXIT:-0}"'
mkfake fake_provision '
if [[ -n "${FAKE_PROVISION_INFO:-}" ]]; then
  printf "CLUSTER_ID=ocid1.cluster.oc1.phx.fakeclusterid\nNODE_POOL_ID=ocid1.nodepool.oc1.phx.fakepoolid\nGPU_SHAPE=VM.GPU.A10.1\nKUBE_CONTEXT=stub-ctx\n" > "${NIMBLE_CLUSTER_INFO}"
fi
sleep "${FAKE_PROVISION_SLEEP:-0}"; exit "${FAKE_PROVISION_EXIT:-0}"'
cat > "${FAKE_DIR}/fake_deploy" <<'EOF2'
#!/bin/bash
echo "fake_deploy $*" >> "${CALLS_LOG}"
# Key-source evidence: names and yes/no only, never a value.
echo "deploy-env KEYLESS=${KEYLESS:-unset} NGC_API_KEY_set=${NGC_API_KEY:+yes} NGC_KEY_KEYCHAIN=${NGC_KEY_KEYCHAIN:-} NGC_KEY_FILE_set=${NGC_KEY_FILE:+yes}" >> "${CALLS_LOG}"
if [[ -n "${FAKE_DEPLOY_HELPER:-}" ]]; then
  # Run the real agent-blind helper, as deploy.sh KEYLESS=1 does.
  "${REPO_ROOT_FOR_FAKE}/scripts/ngc-secrets.sh" create || exit 1
  # create-only: leave the API Secret behind (gate 2 must then fail).
  [[ "${FAKE_DEPLOY_HELPER}" == "create-only" ]] || "${REPO_ROOT_FOR_FAKE}/scripts/ngc-secrets.sh" delete-api || exit 1
fi
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
export REPO_ROOT_FOR_FAKE="${REPO_ROOT}"
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
        FAKE_DEPLOY_SLEEP FAKE_DEPLOY_EXIT FAKE_READY_EXIT FAKE_BENCH_EXIT FAKE_TEARDOWN_EXIT \
        FAKE_PROVISION_INFO NIMBLE_CLUSTER_INFO NIM_LOCAL_PORT STUB_PF_EXIT STUB_PF_SERVE STUB_K8S_VERSIONS \
        ALLOW_SHORT_WATCHDOG OCI_REGION OCI_CLI_REGION \
        FAKE_DEPLOY_HELPER STUB_SECRET_DIR STUB_KEYCHAIN_DB STUB_KEYCHAIN_MISSING STUB_KEYCHAIN_SERVICE \
        STUB_HELM_OK STUB_HELM_FAIL_MATCH STUB_HELM_LIST STUB_DEPLOY_ENV_NAMES \
        STUB_POD_ENV_KEYCOUNT STUB_EXEC_FAIL STUB_POD_ENVFROM STUB_JOB_PRESENT STUB_HELM_VALUES_JSON STUB_HELM_MANIFEST
  : > "${STUB_ENV_LOG}"
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

receipt_ok() {  # $1 OUT_DIR: receipt.md exists, has every section, no OCID/IP/dummy key
  local r="$1/receipt.md"
  [[ -f "${r}" ]] || return 1
  python3 - "${r}" <<'PY2' || return 1
import re, sys
t = open(sys.argv[1]).read()
need = ["# Measured run receipt", "- Date (UTC): ", "- Region: ", "- Shape: ", "- Image: ",
        "- Kubernetes version: ", "## Phases (seconds)", "## Cost", "- Billable seconds",
        "- Estimated cost (USD): ", "- Rate basis: ", "## Bench", "## Teardown", "- Result: "]
missing = [n for n in need if n not in t]
assert not missing, missing
assert re.search(r"^- bench: \d+ \(rc 0\)$", t, re.M), "bench phase line"
assert re.search(r"^- Estimated cost \(USD\): [0-9.]+$", t, re.M), "cost line"
assert "ocid1." not in t and "DUMMYKEY" not in t
assert not re.search(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", t), "IPv4 in receipt"
PY2
}

# --- R1: success path ---
reset
O="${TMP_DIR}/outR1"
export FAKE_PROVISION_INFO=1 NIMBLE_CLUSTER_INFO="${TMP_DIR}/r1-cluster-info.txt"
set +e; "${RUNNER}" "${O}" > "${TMP_DIR}/r1.out" 2>&1; rc=$?; set -e
pass=true
receipt_ok "${O}" || pass=false
grep -q '^kubectl --context stub-ctx version' "${STUB_LOG}" || pass=false
grep -q '^KUBE_CONTEXT=stub-ctx$' "${O}/.oke_ids" || pass=false
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
echo "  receipt.md:"; sed 's/^/    /' "${O}/receipt.md"
echo "  stub kubectl calls: $(grep '^kubectl' "${STUB_LOG}" | tr '\n' ';')"

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
{ [[ -f "${O}/receipt.md" ]] && ! grep -q DUMMYKEY "${O}/receipt.md"; } || pass=false
! ls -d "${TMPDIR:-/tmp}"/nimble-deploy.* >/dev/null 2>&1 || pass=false
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

# --- R13: NIM_LOCAL_PORT busy -> runner picks a free port, forwards it, and passes it to bench ---
reset
O="${TMP_DIR}/outR13"
BUSY_FILE="${TMP_DIR}/busyport"
python3 -c 'import socket,sys,time; s=socket.socket(); s.bind(("127.0.0.1",0)); s.listen(1); open(sys.argv[1],"w").write(str(s.getsockname()[1])); time.sleep(120)' "${BUSY_FILE}" &
busy_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -s "${BUSY_FILE}" ]] && break; sleep 0.3; done
busy="$(cat "${BUSY_FILE}")"
export NIM_LOCAL_PORT="${busy}" STUB_PF_SERVE=1 READY_TIMEOUT_SEC=30
export FAKE_PROVISION_INFO=1 NIMBLE_CLUSTER_INFO="${TMP_DIR}/r13-cluster-info.txt"
set +e; env -u RUNNER_READY "${RUNNER}" "${O}" > "${TMP_DIR}/r13.out" 2>&1; rc=$?; set -e
kill "${busy_pid}" 2>/dev/null || true; wait "${busy_pid}" 2>/dev/null || true
export READY_TIMEOUT_SEC=3
pf_line="$(grep '^kubectl .*port-forward' "${STUB_LOG}" | head -1)"
pf_port="$(printf '%s' "${pf_line}" | sed -n 's/.* \([0-9][0-9]*\):8000.*/\1/p')"
pass=true
[[ "${rc}" -eq 0 ]] || pass=false
[[ -n "${pf_port}" && "${pf_port}" != "${busy}" ]] || pass=false
[[ "${pf_line}" == "kubectl --context stub-ctx port-forward"* ]] || pass=false
grep -q "^fake_bench --url http://127.0.0.1:${pf_port} --out " "${CALLS_LOG}" || pass=false
grep -q "NIM_LOCAL_PORT ${busy} is in use" "${O}/runner.log" || pass=false
receipt_ok "${O}" || pass=false
[[ -z "$(wd_alive "${O}")" ]] || pass=false
hr="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["hourly_rate_usd"])' "${O}/summary.json" 2>/dev/null || echo none)"
want_hr="$(bash -c 'source "$1/scripts/_lib.sh" >/dev/null 2>&1; set +e; estimate_hourly_cost 1 VM.GPU.A10.1' _ "${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}" 2>/dev/null | tail -1)"
python3 -c 'import sys; sys.exit(0 if abs(float(sys.argv[1])-float(sys.argv[2]))<1e-6 else 1)' "${hr}" "${want_hr}" 2>/dev/null || { pass=false; echo "  hourly_rate_usd=${hr} want=${want_hr}"; }
report R13 "${pass}" "rc=${rc} busy=${busy} forwarded=${pf_port} | ${pf_line} | $(grep '^fake_bench' "${CALLS_LOG}")" "${O}"

# --- R19: pod still Pending -> ready waits, starts no port-forward, then passes once Running ---
reset
O="${TMP_DIR}/outR19"
export STUB_PF_SERVE=1 READY_TIMEOUT_SEC=60 STUB_POD_PENDING_POLLS=4 STUB_POD_COUNTER="${TMP_DIR}/r19-pod-polls"
export FAKE_PROVISION_INFO=1 NIMBLE_CLUSTER_INFO="${TMP_DIR}/r19-cluster-info.txt"
set +e; env -u RUNNER_READY "${RUNNER}" "${O}" > "${TMP_DIR}/r19.out" 2>&1; rc=$?; set -e
export READY_TIMEOUT_SEC=3
unset STUB_POD_PENDING_POLLS STUB_POD_COUNTER
waits="$(grep -c 'NIM pod not Running yet' "${O}/ready.log" 2>/dev/null || true)"
pass=true
[[ "${rc}" -eq 0 ]] || pass=false
[[ "${waits}" -ge 4 ]] || pass=false
if grep -q "exited at once" "${O}/ready.log" "${O}/runner.log" 2>/dev/null; then pass=false; fi
[[ "$(grep -c '^kubectl .*port-forward' "${STUB_LOG}")" -eq 1 ]] || pass=false
[[ "$(count bench)" -eq 1 && "$(count teardown)" -eq 1 ]] || pass=false
[[ -z "$(wd_alive "${O}")" ]] || pass=false
report R19 "${pass}" "rc=${rc} pending_waits=${waits} port_forwards=$(grep -c '^kubectl .*port-forward' "${STUB_LOG}") bench_calls=$(count bench)" "${O}"

# --- R14: port-forward dies at once -> ready fails fast (not after READY_TIMEOUT_SEC) ---
reset
O="${TMP_DIR}/outR14"
export STUB_PF_EXIT=1 READY_TIMEOUT_SEC=300
t0=$(date +%s)
set +e; env -u RUNNER_READY "${RUNNER}" "${O}" > "${TMP_DIR}/r14.out" 2>&1; rc=$?; set -e
el=$(( $(date +%s) - t0 ))
export READY_TIMEOUT_SEC=3
pass=true
[[ "${rc}" -ne 0 ]] || pass=false
(( el < 60 )) || pass=false
grep -q "port-forward to svc/nvidia-nim exited at once 3 times" "${O}/runner.log" || pass=false
grep -q "^PHASE ready END [0-9]* rc=1$" "${O}/phases.log" || pass=false
[[ "$(count teardown)" -eq 1 && "$(count bench)" -eq 0 ]] || pass=false
[[ -z "$(wd_alive "${O}")" ]] || pass=false
report R14 "${pass}" "rc=${rc} elapsed=${el}s (READY_TIMEOUT_SEC=300) teardown_calls=$(count teardown) | $(grep -h 'ready FAILED' "${O}/runner.log" | cut -d' ' -f2-)" "${O}"

pass=true
left="$(pgrep -f 'port-forward-stub' || true)"
[[ -z "${left}" ]] || pass=false
report R13b "${pass}" "stub port-forward server stopped by the runner: leftover pids=[${left}]" "${TMP_DIR}"

# --- R15: teardown exit 2 (GPU billing stopped, possible orphans) is reported distinctly ---
reset
O="${TMP_DIR}/outR15"
export FAKE_TEARDOWN_EXIT=2
set +e; "${RUNNER}" "${O}" > "${TMP_DIR}/r15.out" 2>&1; rc=$?; set -e
pass=true
[[ "${rc}" -eq 3 ]] || pass=false
python3 -c 'import json,sys; t=json.load(open(sys.argv[1]))["teardown"]; assert t["result"]=="partial" and t["last_exit_code"]==2 and t["gpu_billing_stopped_possible_orphans"] is True' "${O}/summary.json" || pass=false
grep -q '^- Result: PARTIAL (teardown exit 2): GPU billing stopped' "${O}/receipt.md" || pass=false
pkill -f "watchdog-for .*${O}" 2>/dev/null || true
report R15 "${pass}" "rc=${rc} receipt: $(grep '^- Result:' "${O}/receipt.md" | cut -c1-90)" "${O}"

# --- P1: bc or curl missing -> default preflight fails naming the tool ---
ORIG_PATH="${PATH}"
mk_path_without() {  # $1 tool to omit; prints a PATH of symlinked tools
  local d="${TMP_DIR}/bin-no-$1" t p
  mkdir -p "${d}"
  for t in bash env sh date mkdir ls sed awk ps tail head cat rm tr wc grep python3 printf sleep \
           dirname basename uname mktemp cut sort jq bc curl caffeinate pgrep kill; do
    [[ "${t}" == "$1" ]] && continue
    p="$(PATH="${ORIG_PATH}" command -v "${t}" 2>/dev/null || true)"
    if [[ -n "${p}" && "${p}" == /* ]]; then ln -sf "${p}" "${d}/${t}"; fi
  done
  echo "${STUB_DIR}:${FAKE_DIR}:${d}"
}
for tool in bc curl; do
  reset
  O="${TMP_DIR}/outP1-${tool}"
  rc=0
  PATH="$(mk_path_without "${tool}")" env -u RUNNER_PREFLIGHT -u NGC_API_KEY OKE_GPU_SHAPE=VM.GPU.A10.1 \
    bash "${RUNNER}" --preflight-only "${O}" > "${O}.out" 2>&1 || rc=$?
  pass=true
  [[ "${rc}" -ne 0 ]] || pass=false
  grep -q "^FAIL: required tool not found: ${tool}$" "${O}/preflight.log" || pass=false
  no_side_effects "${O}" || pass=false
  report "P1-${tool}" "${pass}" "rc=${rc} | $(grep -m1 '^FAIL' "${O}/preflight.log")" "${O}"
done

# --- D3: pinned Kubernetes version not offered by OKE -> preflight fails ---
reset
O="${TMP_DIR}/outD3"
export STUB_K8S_VERSIONS='["v1.32.1","v1.33.1"]'
rc="$(pf_only_default "${O}" "${REAL_CFG}")"
pass=true
[[ "${rc}" -ne 0 ]] || pass=false
grep -q "^FAIL: Kubernetes v[0-9.]* (pinned in provision-cluster.sh) is not offered by OKE" "${O}/preflight.log" || pass=false
grep -q '^oci ce cluster-options get --cluster-option-id all' "${STUB_LOG}" || pass=false
no_side_effects "${O}" || pass=false
report D3 "${pass}" "rc=${rc} | $(grep -m1 '^FAIL' "${O}/preflight.log")" "${O}"

# --- R15: --key-file: mode 644 refused; mode 600 accepted; key never in OUT_DIR or argv ---
reset
KF="${TMP_DIR}/ngc.key"
# Unique per run: no ancestor process argv can contain it by accident.
KF_KEY="kf$$x$(date +%s)xdummy"
printf '%s\n' "${KF_KEY}" > "${KF}"
chmod 644 "${KF}"
O="${TMP_DIR}/outR15a"
set +e; env -u NGC_API_KEY "${RUNNER}" --key-file "${KF}" "${O}" > "${TMP_DIR}/r15a.out" 2>&1; rc=$?; set -e
pass=true
[[ "${rc}" -eq 2 ]] || pass=false
grep -q "has mode 644; it must be 600 or 400" "${TMP_DIR}/r15a.out" || pass=false
[[ ! -e "${O}" && "$(count provision)" -eq 0 ]] || pass=false
report R15a "${pass}" "rc=${rc} | $(head -1 "${TMP_DIR}/r15a.out")" "${O}"
reset
chmod 600 "${KF}"
O="${TMP_DIR}/outR15b"
export FAKE_DEPLOY_LEAK=1 FAKE_DEPLOY_SLEEP=3
PS_LOG="${TMP_DIR}/ps_samples15.txt"; : > "${PS_LOG}"
env -u NGC_API_KEY "${RUNNER}" --key-file "${KF}" "${O}" > "${TMP_DIR}/r15b.out" 2>&1 &
r15=$!
samples=0
while kill -0 "${r15}" 2>/dev/null; do
  ps -A -ww -o pid= -o command= >> "${PS_LOG}" 2>/dev/null || true
  samples=$((samples + 1)); sleep 0.2
done
set +e; wait "${r15}"; rc=$?; set -e
file_hits="$(grep -rl -e "${KF_KEY}" "${O}" "${TMP_DIR}/r15b.out" || true)"
argv_hits="$(grep -c -e "${KF_KEY}" "${PS_LOG}" || true)"
redacted="$(grep -c 'REDACTED' "${O}/deploy.log" || true)"
pass=true
[[ "${rc}" -eq 0 ]] || pass=false
[[ -z "${file_hits}" && "${argv_hits}" -eq 0 ]] || pass=false
[[ "${redacted}" -ge 4 && "$(count deploy)" -eq 1 ]] || pass=false
report R15b "${pass}" "rc=${rc} files_with_key=[${file_hits}] ps_samples=${samples} argv_lines_with_key=${argv_hits} redacted_lines=${redacted} (deploy received the key from the file)" "${O}"

# --- R16: the runner's own oci calls see OCI_CLI_REGION == OCI_REGION ---
reset
O="${TMP_DIR}/outR16"
export FAKE_PROVISION_INFO=1 NIMBLE_CLUSTER_INFO="${TMP_DIR}/r16-cluster-info.txt"
set +e; OCI_REGION=us-ashburn-1 OCI_CLI_REGION=eu-frankfurt-1 "${RUNNER}" "${O}" > "${TMP_DIR}/r16.out" 2>&1; rc=$?; set -e
own="$(grep -c '^OCI_CLI_REGION=us-ashburn-1 oci ce .* list .*--region us-ashburn-1' "${STUB_ENV_LOG}" || true)"
other="$(grep -vc '^OCI_CLI_REGION=us-ashburn-1 ' "${STUB_ENV_LOG}" || true)"
pass=true
[[ "${rc}" -eq 0 ]] || pass=false
[[ "${own}" -ge 2 && "${other}" -eq 0 ]] || pass=false
report R16 "${pass}" "rc=${rc} verify-clean oci calls with OCI_CLI_REGION=us-ashburn-1 and --region us-ashburn-1: ${own}; calls with another OCI_CLI_REGION: ${other}" "${O}"
sed 's/^/    /' "${STUB_ENV_LOG}"

# --- R17: WATCHDOG_SEC below the step-budget sum (183) ---
reset
O="${TMP_DIR}/outR17a"
set +e; WATCHDOG_SEC=100 "${RUNNER}" "${O}" > "${TMP_DIR}/r17a.out" 2>&1; rc=$?; set -e
pass=true
[[ "${rc}" -eq 1 ]] || pass=false
grep -q '^FAIL: WATCHDOG_SEC 100 is smaller than the step-budget sum 183' "${O}/preflight.log" || pass=false
[[ "$(count provision)" -eq 0 && "$(count preflight)" -eq 0 && ! -f "${O}/watchdog.pid" ]] || pass=false
report R17a "${pass}" "rc=${rc} | $(grep -m1 '^FAIL' "${O}/preflight.log")" "${O}"
reset
O="${TMP_DIR}/outR17b"
set +e; WATCHDOG_SEC=100 ALLOW_SHORT_WATCHDOG=yes "${RUNNER}" "${O}" > "${TMP_DIR}/r17b.out" 2>&1; rc=$?; set -e
pass=true
[[ "${rc}" -eq 0 && "$(count provision)" -eq 1 && "$(count bench)" -eq 1 ]] || pass=false
grep -q '^WARNING: WATCHDOG_SEC 100 is smaller than the step-budget sum 183; proceeding' "${O}/preflight.log" || pass=false
report R17b "${pass}" "rc=${rc} | $(grep -m1 '^WARNING' "${O}/preflight.log")" "${O}"
reset
O="${TMP_DIR}/outR17c"
set +e; env -u WATCHDOG_SEC -u READY_TIMEOUT_SEC -u PROVISION_STEP_TIMEOUT_SEC -u DEPLOY_STEP_TIMEOUT_SEC \
  -u BENCH_STEP_TIMEOUT_SEC "${RUNNER}" --preflight-only "${O}" > "${TMP_DIR}/r17c.out" 2>&1; rc=$?; set -e
pass=true
[[ "${rc}" -eq 0 ]] || pass=false
grep -q '= 7800s; WATCHDOG_SEC=9000s$' "${O}/preflight.log" || pass=false
report R17c "${pass}" "rc=${rc} defaults | $(grep -m1 '^step budgets' "${O}/preflight.log")" "${O}"

# --- R18: deploy past its hard timeout -> stopped, teardown runs ---
reset
O="${TMP_DIR}/outR18"
export FAKE_PROVISION_INFO=1 NIMBLE_CLUSTER_INFO="${TMP_DIR}/r18-cluster-info.txt" FAKE_DEPLOY_SLEEP=60
t0=$(date +%s)
set +e; DEPLOY_STEP_TIMEOUT_SEC=2 "${RUNNER}" "${O}" > "${TMP_DIR}/r18.out" 2>&1; rc=$?; set -e
el=$(( $(date +%s) - t0 ))
pass=true
[[ "${rc}" -eq 1 && "${el}" -lt 30 ]] || pass=false
grep -q 'step deploy exceeded its hard timeout of 2s' "${O}/runner.log" || pass=false
grep -q '^PHASE deploy END [0-9]* rc=124$' "${O}/phases.log" || pass=false
[[ "$(count teardown)" -ge 1 && "$(count ready)" -eq 0 ]] || pass=false
! pgrep -f "sleep 60" >/dev/null 2>&1 || pass=false
report R18 "${pass}" "rc=${rc} elapsed=${el}s teardown_calls=$(count teardown) | $(grep -m1 'hard timeout' "${O}/runner.log" | cut -d' ' -f2-)" "${O}"

# =================== Keyless path and Keychain key source ===================
# leak_scan KEY PATH...: prints every file under PATH that holds KEY in plain
# text or inside base64 (one or two layers deep: a Secret's data field, a
# dockerconfigjson auth field). Never prints the key.
leak_scan() {
  python3 - "$@" <<'PYLEAK'
import base64, binascii, os, re, sys
key = sys.argv[1].encode()
tok = re.compile(rb"[A-Za-z0-9+/_-]{12,}={0,2}")
def has(b, depth=0):
    if key in b:
        return True
    if depth >= 2:
        return False
    for m in tok.finditer(b):
        t = m.group(0)
        p = t + b"=" * (-len(t) % 4)
        for dec in (base64.b64decode, base64.urlsafe_b64decode):
            try:
                if has(dec(p), depth + 1):
                    return True
            except (binascii.Error, ValueError):
                pass
    return False
def files(p):
    if os.path.isdir(p):
        for r, _, fs in os.walk(p):
            for f in fs:
                yield os.path.join(r, f)
    elif os.path.isfile(p):
        yield p
hits = []
for p in sys.argv[2:]:
    for f in files(p):
        try:
            b = open(f, "rb").read()
        except OSError:
            continue
        if has(b):
            hits.append(f)
print(" ".join(hits))
PYLEAK
}
fake_key() { printf 'nvapi-FAKE-%s-%s-%s-placeholder' "$1" "$$" "$(date +%s)"; }
w_reads() { grep -c '^security find-generic-password -w ' "${STUB_LOG}" 2>/dev/null || true; }
clear_secrets() { rm -f "${STUB_SECRET_DIR:?}"/nvidia-nim-ngc-*; }

# --- K0: the leak scanner finds the key in plain text, base64, and a base64 dockerconfigjson ---
K0KEY="$(fake_key k0)"
K0D="${TMP_DIR}/k0"; mkdir -p "${K0D}"
printf 'x %s y\n' "${K0KEY}" > "${K0D}/plain"
printf 'NGC_API_KEY: %s\n' "$(printf %s "${K0KEY}" | base64 | tr -d '\n')" > "${K0D}/b64"
printf '.dockerconfigjson: %s\n' "$(printf '{"auths":{"nvcr.io":{"password":"%s"}}}' "${K0KEY}" | base64 | tr -d '\n')" > "${K0D}/dcj"
printf 'nothing here\n' > "${K0D}/clean"
k0="$(leak_scan "${K0KEY}" "${K0D}")"
pass=true
for f in plain b64 dcj; do [[ " ${k0} " == *"/${f} "* ]] || pass=false; done
[[ " ${k0} " != *"/clean "* ]] || pass=false
report K0 "${pass}" "scanner positive controls: hits=[$(for f in ${k0}; do basename "${f}"; done | tr '\n' ' ')]" "${TMP_DIR}"

# --- K1: --key-keychain end to end through the runner (stub Keychain, stub Secret store) ---
reset
O="${TMP_DIR}/outK1"
K1KEY="$(fake_key k1)"
export STUB_KEYCHAIN_DB="${TMP_DIR}/k1-keychain.db"; printf '%s\n' "${K1KEY}" > "${STUB_KEYCHAIN_DB}"
export STUB_SECRET_DIR="${TMP_DIR}/k1-secrets"; mkdir -p "${STUB_SECRET_DIR}"
export FAKE_DEPLOY_HELPER=1 FAKE_DEPLOY_SLEEP=2 STUB_HELM_OK=1
export FAKE_PROVISION_INFO=1 NIMBLE_CLUSTER_INFO="${TMP_DIR}/k1-cluster-info.txt"
PS_LOG="${TMP_DIR}/ps_samplesK1.txt"; : > "${PS_LOG}"
# NGC_API_KEY stays set to the suite's dummy: the runner must drop it.
"${RUNNER}" --key-keychain nimble-test-ngc "${O}" > "${TMP_DIR}/k1.stdout" 2> "${TMP_DIR}/k1.stderr" &
k1=$!
samples=0
while kill -0 "${k1}" 2>/dev/null; do
  ps -A -ww -o pid= -o command= >> "${PS_LOG}" 2>/dev/null || true
  samples=$((samples + 1)); sleep 0.2
done
set +e; wait "${k1}"; rc=$?; set -e
denv="$(grep '^deploy-env ' "${CALLS_LOG}" || true)"
hits="$(leak_scan "${K1KEY}" "${O}" "${TMP_DIR}/k1.stdout" "${TMP_DIR}/k1.stderr" "${STUB_LOG}" "${CALLS_LOG}")"
argv_hits="$(grep -c -e "${K1KEY}" "${PS_LOG}" || true)"
reg_ok="$(python3 - "${STUB_SECRET_DIR}/nvidia-nim-ngc-registry" "${STUB_KEYCHAIN_DB}" <<'PY' 2>/dev/null || echo no
import base64, json, sys
d = json.load(open(sys.argv[1]))["auths"]["nvcr.io"]
k = open(sys.argv[2]).read().splitlines()[0]
ok = d["username"] == "$oauthtoken" and d["password"] == k and base64.b64decode(d["auth"]).decode() == "$oauthtoken:" + k
print("yes" if ok else "no")
PY
)"
pass=true
[[ "${rc}" -eq 0 ]] || pass=false
[[ "${denv}" == "deploy-env KEYLESS=1 NGC_API_KEY_set= NGC_KEY_KEYCHAIN=nimble-test-ngc NGC_KEY_FILE_set=" ]] || pass=false
grep -q '^security find-generic-password -s nimble-test-ngc$' "${STUB_LOG}" || pass=false
[[ "$(w_reads)" -eq 2 ]] || pass=false
[[ "${reg_ok}" == "yes" && ! -e "${STUB_SECRET_DIR}/nvidia-nim-ngc-api" ]] || pass=false
[[ -z "${hits}" && "${argv_hits}" -eq 0 ]] || pass=false
python3 -c 'import json,sys; k=json.load(open(sys.argv[1]))["ngc_key"]; assert k=={"source":"keychain","keyless_serve":True}, k' "${O}/summary.json" || pass=false
grep -q '^- NGC key source: keychain; keyless serve: yes$' "${O}/receipt.md" || pass=false
receipt_ok "${O}" || pass=false
k1order="$(grep ' START ' "${O}/phases.log" | awk '{print $2}' | tr '\n' ' ')"
[[ "${k1order}" == "preflight provision deploy ready keyless-check bench teardown verify-clean " ]] || pass=false
grep -q '^gate1: PASS (runtime count 0; pod spec clean)$' "${O}/keyless-evidence.log" || pass=false
grep -q '^gate2: PASS (nvidia-nim-ngc-api NotFound)$' "${O}/keyless-evidence.log" || pass=false
grep -q '^release_secret: PASS ' "${O}/keyless-evidence.log" || pass=false
python3 -c 'import json,sys; g=json.load(open(sys.argv[1]))["keyless_gates"]; assert all(g[k].startswith("PASS") for k in ("gate1","gate2","release_secret")), g' "${O}/summary.json" || pass=false
grep -q '^- Gate 1, server pod env has no NGC_API_KEY: PASS' "${O}/receipt.md" || pass=false
grep -q '^- Gate 2, no API Secret after pre-stage: PASS' "${O}/receipt.md" || pass=false
[[ -z "$(wd_alive "${O}")" ]] || pass=false
report K1 "${pass}" "rc=${rc} | ${denv} | keychain -w reads=$(w_reads) (helper only) | pull secret dockerconfigjson matches=${reg_ok}; api secret left=$([[ -e "${STUB_SECRET_DIR}/nvidia-nim-ngc-api" ]] && echo yes || echo no) | files_with_key=[${hits}] ps_samples=${samples} argv_lines_with_key=${argv_hits}" "${O}"
echo "  phases: ${k1order% }"
echo "  keyless-evidence.log:"; sed 's/^/    /' "${O}/keyless-evidence.log"
echo "  stub calls (key source and Secrets):"; grep -E '^(security|kubectl-stdin)|secret' "${STUB_LOG}" | sed 's/^/    /'

# --- K2: Keychain item missing -> preflight fails before anything billable; no -w read ---
reset
O="${TMP_DIR}/outK2"
export STUB_KEYCHAIN_MISSING=1
set +e; "${RUNNER}" --key-keychain nimble-test-ngc "${O}" > "${TMP_DIR}/k2.out" 2>&1; rc=$?; set -e
pass=true
[[ "${rc}" -eq 1 && "$(count provision)" -eq 0 && "$(w_reads)" -eq 0 && ! -f "${O}/watchdog.pid" ]] || pass=false
grep -q '^FAIL: OCI_COMPARTMENT_ID and NGC_API_KEY must be set (or a usable --key-file / --key-keychain source)$' "${O}/preflight.log" || pass=false
report K2a "${pass}" "rc=${rc} provision_calls=$(count provision) -w_reads=$(w_reads) | $(grep -m1 '^FAIL' "${O}/preflight.log")" "${O}"
reset
O="${TMP_DIR}/outK2b"
rc=0
env -u RUNNER_PREFLIGHT -u NGC_API_KEY RUNNER_OKE_CONFIG="${REAL_CFG}" OKE_GPU_SHAPE=VM.GPU.A10.1 \
  "${RUNNER}" --preflight-only --key-keychain nimble-test-ngc "${O}" > "${O}.out" 2>&1 || rc=$?
pass=true
[[ "${rc}" -eq 0 && "$(w_reads)" -eq 0 ]] || pass=false
grep -q '^ok: Keychain item present$' "${O}/preflight.log" || pass=false
no_side_effects "${O}" || pass=false
report K2b "${pass}" "default preflight rc=${rc} -w_reads=$(w_reads) | $(grep -m1 'Keychain' "${O}/preflight.log"); $(grep -m1 '^ok: Keychain' "${O}/preflight.log")" "${O}"

# --- K3: --key-keychain with --key-file or --autoscale -> usage error, nothing started ---
reset
KF3="${TMP_DIR}/k3.key"; printf '%s\n' "$(fake_key k3)" > "${KF3}"; chmod 600 "${KF3}"
pass=true; why=""; n=0
for args in "--key-keychain nimble-test-ngc --key-file ${KF3}" "--key-keychain nimble-test-ngc --autoscale" "--keyless --autoscale"; do
  n=$((n + 1)); O="${TMP_DIR}/outK3-${n}"
  rc=0
  # shellcheck disable=SC2086
  "${RUNNER}" ${args} "${O}" > "${O}.out" 2>&1 || rc=$?
  [[ "${rc}" -eq 2 && ! -e "${O}" ]] || pass=false
  why="${why}[${args/${KF3}/KEYFILE}: rc=${rc} $(head -1 "${O}.out")] "
done
[[ "$(count provision)" -eq 0 && "$(w_reads)" -eq 0 ]] || pass=false
report K3 "${pass}" "${why}" "${TMP_DIR}"

# --- K4..K5: deploy.sh KEYLESS=1 against stubs (kubectl Secret store, helm, security, curl) ---
KD_HOME="${TMP_DIR}/kdhome"; KD_BIN="${TMP_DIR}/kdbin"
mkdir -p "${KD_HOME}/.oci" "${KD_HOME}/.kube" "${KD_BIN}"
: > "${KD_HOME}/.oci/config"; : > "${KD_HOME}/.kube/config"
printf '#!/bin/bash\necho "curl $*" >> "${STUB_LOG}"\nprintf 000\n' > "${KD_BIN}/curl"; chmod +x "${KD_BIN}/curl"
# deploy.sh records a deploy timestamp in scripts/ on success; remove it
# afterwards unless it was already there.
DEPLOYED_AT="${REPO_ROOT}/scripts/.nim-deployed-at"
had_deployed_at=no; [[ -e "${DEPLOYED_AT}" ]] && had_deployed_at=yes
run_keyless_deploy() {  # $1 tag; env: KD_KEY; extra env from the caller
  export STUB_KEYCHAIN_DB="${TMP_DIR}/$1-keychain.db"; printf '%s\n' "${KD_KEY}" > "${STUB_KEYCHAIN_DB}"
  export STUB_SECRET_DIR="${TMP_DIR}/$1-secrets"; mkdir -p "${STUB_SECRET_DIR}"
  export NIMBLE_CLUSTER_INFO="${TMP_DIR}/$1-cluster-info.txt"; printf 'KUBE_CONTEXT=stub-ctx\n' > "${NIMBLE_CLUSTER_INFO}"
  local rc=0
  env -u NGC_API_KEY HOME="${KD_HOME}" PATH="${STUB_DIR}:${KD_BIN}:${PATH}" STUB_HELM_OK=1 STUB_CLUSTER=present \
    KEYLESS=1 NGC_KEY_KEYCHAIN=nimble-test-ngc CONFIRM_COST=yes \
    bash "${REPO_ROOT}/scripts/deploy.sh" > "${TMP_DIR}/$1.stdout" 2> "${TMP_DIR}/$1.stderr" || rc=$?
  KD_RC="${rc}"
}
lineno() { grep -n -m1 -e "$1" "${STUB_LOG}" | cut -d: -f1; }

reset
KD_KEY="$(fake_key k4)"
run_keyless_deploy k4; rc="${KD_RC}"
stdin_lines="$(grep '^helm-stdin' "${STUB_LOG}" || true)"
l_reg="$(lineno 'kubectl-stdin secret=nvidia-nim-ngc-registry key=.dockerconfigjson')"
l_api="$(lineno 'kubectl-stdin secret=nvidia-nim-ngc-api key=NGC_API_KEY')"
l_pre="$(lineno '^helm upgrade --install .* --wait --wait-for-jobs')"
l_del="$(grep -n 'delete secret nvidia-nim-ngc-api' "${STUB_LOG}" | cut -d: -f1 | awk -v p="${l_pre:-0}" '$1 > p' | head -1)"
l_srv="$(grep -n '^helm upgrade --install ' "${STUB_LOG}" | grep -v -e '--dry-run' -e '--wait-for-jobs' | head -1 | cut -d: -f1)"
hits="$(leak_scan "${KD_KEY}" "${TMP_DIR}/k4.stdout" "${TMP_DIR}/k4.stderr" "${STUB_LOG}")"
pass=true
[[ "${rc}" -eq 0 ]] || pass=false
[[ "$(printf '%s\n' "${stdin_lines}" | grep -c 'apiKey_value=no keyless=yes')" -eq 3 ]] || pass=false
! printf '%s\n' "${stdin_lines}" | grep -q 'apiKey_value=yes' || pass=false
[[ "$(printf '%s\n' "${stdin_lines}" | grep -c 'prestage=yes replicas=0')" -eq 2 ]] || pass=false
[[ "$(printf '%s\n' "${stdin_lines}" | grep -c 'prestage=no replicas=1')" -eq 1 ]] || pass=false
[[ -n "${l_reg}" && -n "${l_api}" && -n "${l_pre}" && -n "${l_del}" && -n "${l_srv}" ]] || pass=false
(( ${l_reg:-0} < ${l_pre:-0} && ${l_api:-0} < ${l_pre:-0} && ${l_pre:-0} < ${l_del:-0} && ${l_del:-0} < ${l_srv:-0} )) || pass=false
[[ -e "${STUB_SECRET_DIR}/nvidia-nim-ngc-registry" && ! -e "${STUB_SECRET_DIR}/nvidia-nim-ngc-api" ]] || pass=false
grep -q 'Keyless check: no nvidia-nim-ngc-api Secret; Deployment env has no NGC_API_KEY' "${TMP_DIR}/k4.stderr" || pass=false
grep -q 'NGC model access check skipped' "${TMP_DIR}/k4.stderr" || pass=false
[[ "$(w_reads)" -eq 2 && -z "${hits}" ]] || pass=false
report K4 "${pass}" "rc=${rc} order(line): pull-secret=${l_reg} api-secret=${l_api} prestage-install=${l_pre} api-secret-delete=${l_del} serve-install=${l_srv} | -w_reads=$(w_reads) | files_with_key=[${hits}]" "${TMP_DIR}"
[[ "${pass}" == "true" ]] || { echo "--- k4.stderr ---"; tail -30 "${TMP_DIR}/k4.stderr"; }
echo "  helm stdin (switches only; a key would show as apiKey_value=yes):"; printf '%s\n' "${stdin_lines}" | sed 's/^/    /'
echo "  helm calls:"; grep '^helm upgrade' "${STUB_LOG}" | sed 's/^/    /'

reset
KD_KEY="$(fake_key k5a)"
STUB_HELM_FAIL_MATCH=--wait-for-jobs run_keyless_deploy k5a; rc="${KD_RC}"
hits="$(leak_scan "${KD_KEY}" "${TMP_DIR}/k5a.stdout" "${TMP_DIR}/k5a.stderr" "${STUB_LOG}")"
left="$(ls -A "${STUB_SECRET_DIR}" | tr '\n' ' ')"
pass=true
[[ "${rc}" -ne 0 && -z "${left}" && -z "${hits}" ]] || pass=false
[[ "$(grep -c '^helm upgrade --install' "${STUB_LOG}")" -eq 2 ]] || pass=false   # dry-run + failed pre-stage; no serve
grep -q 'NIM FAILURE DIAGNOSTICS' "${TMP_DIR}/k5a.stdout" || pass=false
report K5a "${pass}" "pre-stage fails: rc=${rc} secrets_left=[${left}] helm_installs=$(grep -c '^helm upgrade --install' "${STUB_LOG}") files_with_key=[${hits}]" "${TMP_DIR}"

reset
KD_KEY="$(fake_key k5b)"
STUB_DEPLOY_ENV_NAMES='NGC_API_KEY NIM_CACHE_PATH' run_keyless_deploy k5b; rc="${KD_RC}"
left="$(ls -A "${STUB_SECRET_DIR}" | tr '\n' ' ')"
pass=true
[[ "${rc}" -ne 0 && -z "${left}" ]] || pass=false
grep -q 'Keyless check failed: the Deployment still sets NGC_API_KEY' "${TMP_DIR}/k5b.stderr" || pass=false
report K5b "${pass}" "env still has NGC_API_KEY: rc=${rc} secrets_left=[${left}] | $(grep -m1 'Keyless check failed' "${TMP_DIR}/k5b.stderr" | sed 's/^.*\[ERROR\] //')" "${TMP_DIR}"
reset
KD_KEY="$(fake_key k5c)"
STUB_HELM_LIST=nvidia-nim run_keyless_deploy k5c; rc="${KD_RC}"
pass=true
[[ "${rc}" -ne 0 && -z "$(ls -A "${STUB_SECRET_DIR}")" && "$(w_reads)" -eq 0 ]] || pass=false
[[ "$(grep '^helm upgrade --install' "${STUB_LOG}" | grep -vc -- '--dry-run' || true)" -eq 0 ]] || pass=false
grep -q 'KEYLESS=1 needs a fresh release; release nvidia-nim exists' "${TMP_DIR}/k5c.stderr" || pass=false
report K5c "${pass}" "existing release refused: rc=${rc} installs=$(grep '^helm upgrade --install' "${STUB_LOG}" | grep -vc -- '--dry-run' || true) -w_reads=$(w_reads) | $(grep -m1 'needs a fresh release' "${TMP_DIR}/k5c.stderr" | sed 's/^.*\[ERROR\] //')" "${TMP_DIR}"
if [[ "${had_deployed_at}" == "no" ]]; then rm -f "${DEPLOYED_AT}"; fi

# --- K6: ngc-secrets.sh key sources and refusals ---
reset
K6KEY="$(fake_key k6)"
export STUB_SECRET_DIR="${TMP_DIR}/k6-secrets"; mkdir -p "${STUB_SECRET_DIR}"
HELPER="${REPO_ROOT}/scripts/ngc-secrets.sh"
K6F="${TMP_DIR}/k6.key"; printf '%s\n' "${K6KEY}" > "${K6F}"
K6OUT="${TMP_DIR}/k6.out"; : > "${K6OUT}"
pass=true; why=""
chmod 644 "${K6F}"
rc=0; env -u NGC_API_KEY "${HELPER}" create-api --key-file "${K6F}" >> "${K6OUT}" 2>&1 || rc=$?
[[ "${rc}" -ne 0 && ! -e "${STUB_SECRET_DIR}/nvidia-nim-ngc-api" ]] || pass=false; why="${why}file644 rc=${rc}; "
chmod 600 "${K6F}"
rc=0; env -u NGC_API_KEY "${HELPER}" create-api --key-file "${K6F}" >> "${K6OUT}" 2>&1 || rc=$?
[[ "${rc}" -eq 0 && "$(cat "${STUB_SECRET_DIR}/nvidia-nim-ngc-api")" == "${K6KEY}" ]] || pass=false
[[ "$(wc -c < "${STUB_SECRET_DIR}/nvidia-nim-ngc-api" | tr -d ' ')" -eq "${#K6KEY}" ]] || pass=false
why="${why}file600 rc=${rc} stored=exact key, no newline; "
clear_secrets
rc=0; NGC_API_KEY="${K6KEY}" "${HELPER}" create-api >> "${K6OUT}" 2>&1 || rc=$?
[[ "${rc}" -eq 0 && "$(cat "${STUB_SECRET_DIR}/nvidia-nim-ngc-api")" == "${K6KEY}" ]] || pass=false; why="${why}env rc=${rc}; "
clear_secrets
export STUB_KEYCHAIN_DB="${TMP_DIR}/k6-empty.db"; : > "${STUB_KEYCHAIN_DB}"
rc=0; env -u NGC_API_KEY "${HELPER}" create --key-keychain nimble-test-ngc >> "${K6OUT}" 2>&1 || rc=$?
[[ "${rc}" -ne 0 && -z "$(ls -A "${STUB_SECRET_DIR}")" ]] || pass=false; why="${why}empty-keychain rc=${rc} secrets_left=[$(ls -A "${STUB_SECRET_DIR}" | tr '\n' ' ')]; "
: > "${STUB_LOG}"
rc=0; env -u NGC_API_KEY "${HELPER}" check --key-keychain nimble-test-ngc >> "${K6OUT}" 2>&1 || rc=$?
[[ "${rc}" -eq 0 && "$(w_reads)" -eq 0 ]] || pass=false; why="${why}check rc=${rc} -w_reads=$(w_reads); "
rc=0; env -u NGC_API_KEY "${HELPER}" create >> "${K6OUT}" 2>&1 || rc=$?
[[ "${rc}" -ne 0 ]] || pass=false; why="${why}no-source rc=${rc}"
hits="$(leak_scan "${K6KEY}" "${K6OUT}" "${STUB_LOG}")"
[[ -z "${hits}" ]] || pass=false
report K6 "${pass}" "${why} | files_with_key=[${hits}]" "${TMP_DIR}"


# --- K8: keyless-check phase failures and fallbacks (runner, stubs) ---
k8_run() {  # $1 tag; call reset and export the case's stub knobs first; sets K8_RC and O
  O="${TMP_DIR}/out$1"
  export STUB_KEYCHAIN_DB="${TMP_DIR}/$1-keychain.db"; printf '%s\n' "$(fake_key "$1")" > "${STUB_KEYCHAIN_DB}"
  export STUB_SECRET_DIR="${TMP_DIR}/$1-secrets"; mkdir -p "${STUB_SECRET_DIR}"
  export FAKE_DEPLOY_HELPER="${K8_HELPER:-1}" STUB_HELM_OK=1
  export FAKE_PROVISION_INFO=1 NIMBLE_CLUSTER_INFO="${TMP_DIR}/$1-cluster-info.txt"
  K8_RC=0
  "${RUNNER}" --key-keychain nimble-test-ngc "${O}" > "${TMP_DIR}/$1.out" 2>&1 || K8_RC=$?
}
k8_line() { grep -m1 "^$1: " "${O}/keyless-evidence.log" 2>/dev/null | cut -c1-120; }

reset; export STUB_POD_ENV_KEYCOUNT=1; k8_run K8a
pass=true
[[ "${K8_RC}" -eq 1 && "$(count bench)" -eq 0 && "$(count teardown)" -eq 1 ]] || pass=false
grep -q '^PHASE keyless-check END [0-9]* rc=1$' "${O}/phases.log" || pass=false
grep -q '^gate1: FAIL (runtime count 1;' "${O}/keyless-evidence.log" || pass=false
grep -q '^- Gate 1, server pod env has no NGC_API_KEY: FAIL' "${O}/receipt.md" || pass=false
[[ -z "$(wd_alive "${O}")" ]] || pass=false
report K8a "${pass}" "runtime env has the key: rc=${K8_RC} bench_calls=$(count bench) teardown_calls=$(count teardown) | $(k8_line gate1)" "${O}"

reset; K8_HELPER=create-only k8_run K8b
pass=true
[[ "${K8_RC}" -eq 1 && "$(count bench)" -eq 0 && "$(count teardown)" -eq 1 ]] || pass=false
grep -q '^gate2: FAIL (nvidia-nim-ngc-api: secret/nvidia-nim-ngc-api)$' "${O}/keyless-evidence.log" || pass=false
grep -q '^gate1: PASS' "${O}/keyless-evidence.log" || pass=false
report K8b "${pass}" "API Secret left behind: rc=${K8_RC} bench_calls=$(count bench) | $(k8_line gate2)" "${O}"

reset; export STUB_EXEC_FAIL=1; k8_run K8c
pass=true
[[ "${K8_RC}" -eq 0 && "$(count bench)" -eq 1 ]] || pass=false
grep -q '^G1a runtime env, count of NGC_API_KEY: unavailable$' "${O}/keyless-evidence.log" || pass=false
grep -q '^gate1: PASS (pod spec only: env names \[NIM_CACHE_PATH\], no envFrom; kubectl exec unavailable)$' "${O}/keyless-evidence.log" || pass=false
report K8c "${pass}" "exec unavailable: rc=${K8_RC} bench_calls=$(count bench) | $(k8_line gate1)" "${O}"

reset; export STUB_EXEC_FAIL=1 STUB_DEPLOY_ENV_NAMES='NGC_API_KEY NIM_CACHE_PATH'; k8_run K8d
pass=true
[[ "${K8_RC}" -eq 1 && "$(count bench)" -eq 0 ]] || pass=false
grep -q '^gate1: FAIL ' "${O}/keyless-evidence.log" || pass=false
report K8d "${pass}" "pod spec names NGC_API_KEY: rc=${K8_RC} | $(k8_line gate1)" "${O}"

K8EKEY="$(fake_key k8e)"
reset; export STUB_HELM_VALUES_JSON="{\"ngc\":{\"keyless\":true,\"apiKey\":\"${K8EKEY}\"}}"; k8_run K8e
hits="$(leak_scan "${K8EKEY}" "${O}" "${TMP_DIR}/K8e.out")"
pass=true
[[ "${K8_RC}" -eq 1 && "$(count bench)" -eq 0 && -z "${hits}" ]] || pass=false
grep -q "^S1 Helm values ngc.apiKey length: ${#K8EKEY}$" "${O}/keyless-evidence.log" || pass=false
grep -q '^release_secret: FAIL ' "${O}/keyless-evidence.log" || pass=false
report K8e "${pass}" "key in Helm values: rc=${K8_RC} | $(k8_line release_secret) | files_with_key=[${hits}]" "${O}"

reset
O="${TMP_DIR}/outK8f"
rc=0
env -u WATCHDOG_SEC -u READY_TIMEOUT_SEC -u PROVISION_STEP_TIMEOUT_SEC -u DEPLOY_STEP_TIMEOUT_SEC \
  -u BENCH_STEP_TIMEOUT_SEC "${RUNNER}" --key-keychain nimble-test-ngc --preflight-only "${O}" > "${O}.out" 2>&1 || rc=$?
pass=true
[[ "${rc}" -eq 0 ]] || pass=false
grep -q '^step budgets: provision 3600s + deploy 3600s + ready 900s + bench 900s + keyless-check 120s = 9120s; WATCHDOG_SEC=10320s$' "${O}/preflight.log" || pass=false
report K8f "${pass}" "keyless defaults rc=${rc} | $(grep -m1 '^step budgets' "${O}/preflight.log")" "${O}"

# --- K7: helm template on the keyless path (real helm) ---
if [[ -z "${REAL_HELM}" ]]; then
  echo "K7 SKIP  helm not installed: helm template checks NOT RUN"
else
  # The exact values deploy.sh pipes to helm on the keyless path.
  eval "$(sed -n '/^keyless_values_yaml()/,/^}/p' "${REPO_ROOT}/scripts/deploy.sh")"
  K7KEY="$(fake_key k7)"
  K7D="${TMP_DIR}/k7"; mkdir -p "${K7D}"
  # The fake key sits in helm's environment, as an operator's shell might hold it.
  hrender() { NGC_API_KEY="${K7KEY}" "${REAL_HELM}" template nvidia-nim "${REPO_ROOT}/helm" -f "${REPO_ROOT}/helm/values.yaml" -f - "$@"; }
  rs=0; keyless_values_yaml false 1 | hrender > "${K7D}/serve.yaml" 2> "${K7D}/serve.err" || rs=$?
  rp=0; keyless_values_yaml true 0 | hrender > "${K7D}/prestage.yaml" 2> "${K7D}/prestage.err" || rp=$?
  keyless_values_yaml true 0 | hrender --show-only templates/deployment.yaml > "${K7D}/prestage-deploy.yaml" 2>&1 || true
  rr=0; printf 'ngc:\n  keyless: true\n  apiKey: "%s"\n' "${K7KEY}" | hrender > "${K7D}/refuse.yaml" 2> "${K7D}/refuse.err" || rr=$?
  printf 'ngc:\n  apiKey: "%s"\n' "${K7KEY}" | hrender > "${K7D}/control-default.yaml" 2>&1 || true
  hits="$(leak_scan "${K7KEY}" "${K7D}/serve.yaml" "${K7D}/serve.err" "${K7D}/prestage.yaml" "${K7D}/prestage.err" "${K7D}/refuse.yaml" "${K7D}/refuse.err")"
  ctrl="$(leak_scan "${K7KEY}" "${K7D}/control-default.yaml")"
  pass=true
  [[ "${rs}" -eq 0 && "${rp}" -eq 0 ]] || pass=false
  ! grep -q 'NGC_API_KEY' "${K7D}/serve.yaml" || pass=false
  ! grep -q 'ngc-api' "${K7D}/serve.yaml" || pass=false
  ! grep -q '^kind: Secret' "${K7D}/serve.yaml" "${K7D}/prestage.yaml" || pass=false
  ! grep -q '^kind: Job' "${K7D}/serve.yaml" || pass=false
  grep -q -- '- name: nvidia-nim-ngc-registry' "${K7D}/serve.yaml" || pass=false
  grep -q '^  replicas: 1$' "${K7D}/serve.yaml" || pass=false
  grep -q '^kind: Job' "${K7D}/prestage.yaml" || pass=false
  { grep -q '^  replicas: 0$' "${K7D}/prestage-deploy.yaml" && ! grep -q 'NGC_API_KEY' "${K7D}/prestage-deploy.yaml"; } || pass=false
  { [[ "${rr}" -ne 0 ]] && grep -q 'ngc.keyless=true requires ngc.apiKey to be empty' "${K7D}/refuse.err"; } || pass=false
  # Pre-stage Job: the cache PVC at the chart path AND at NIM's default path;
  # the server keeps the single chart path. A mountPath already equal to the
  # default renders one mount (no duplicate mountPath).
  keyless_values_yaml true 0 | hrender --show-only templates/prestage-job.yaml > "${K7D}/job.yaml" 2>&1 || true
  job_mounts="$(grep -A1 -- '- name: model-cache$' "${K7D}/job.yaml" | sed -n 's/^ *mountPath: //p' | tr '\n' ' ')"
  srv_mounts="$(grep -A1 -- '- name: model-cache$' "${K7D}/serve.yaml" | sed -n 's/^ *mountPath: //p' | tr '\n' ' ')"
  { printf 'persistence:\n  mountPath: /opt/nim/.cache\n'; keyless_values_yaml true 0; } \
    | hrender --show-only templates/prestage-job.yaml > "${K7D}/job-default.yaml" 2>&1 || true
  def_mounts="$(grep -A1 -- '- name: model-cache$' "${K7D}/job-default.yaml" | sed -n 's/^ *mountPath: //p' | tr '\n' ' ')"
  [[ "${job_mounts}" == "/model-cache /opt/nim/.cache " ]] || pass=false
  grep -A1 -- '- name: NIM_CACHE_PATH$' "${K7D}/job.yaml" | grep -q 'value: "/model-cache"$' || pass=false
  [[ "${srv_mounts}" == "/model-cache " ]] || pass=false
  [[ "${def_mounts}" == "/opt/nim/.cache " ]] || pass=false
  [[ -z "${hits}" && -n "${ctrl}" ]] || pass=false
  report K7 "${pass}" "helm $("${REAL_HELM}" version --short) | serve: NGC_API_KEY lines=$(grep -c 'NGC_API_KEY' "${K7D}/serve.yaml" || true) ngc-api refs=$(grep -c 'ngc-api' "${K7D}/serve.yaml" || true) Secret kinds=$(grep -c '^kind: Secret' "${K7D}/serve.yaml" || true) | prestage: Job=$(grep -c '^kind: Job' "${K7D}/prestage.yaml" || true) Deployment NGC_API_KEY lines=$(grep -c 'NGC_API_KEY' "${K7D}/prestage-deploy.yaml" || true) | keyless+apiKey refused rc=${rr} | files_with_key=[${hits}] | positive control (default path) found key: $([[ -n "${ctrl}" ]] && echo yes || echo no)" "${TMP_DIR}"
  echo "  cache mounts: job=[${job_mounts% }] server=[${srv_mounts% }] job-with-default-mountPath=[${def_mounts% }]"
  echo "  serve render, kinds: $(grep '^kind:' "${K7D}/serve.yaml" | awk '{print $2}' | tr '\n' ' ')"
  echo "  prestage render, kinds: $(grep '^kind:' "${K7D}/prestage.yaml" | awk '{print $2}' | tr '\n' ' ')"
fi

if [[ "${FAIL}" -ne 0 ]]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: all passed"
