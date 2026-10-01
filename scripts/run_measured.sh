#!/usr/bin/env bash
# Measured-run runner for Oracle OKE:
#   preflight -> provision -> deploy -> ready -> bench -> teardown -> verify-clean
#
# Ported from the GKE runner in the sibling nim-gke repo (scripts/run_measured.sh).
# It produces a timed receipt that an NVIDIA NIM container served inference,
# and it ALWAYS tries to tear the paid resources down.
#
# Usage: export NGC_API_KEY first (e.g. `read -rs NGC_API_KEY; export NGC_API_KEY`),
#        then: OCI_COMPARTMENT_ID=... scripts/run_measured.sh OUT_DIR
#    or: OCI_COMPARTMENT_ID=... scripts/run_measured.sh --key-file PATH OUT_DIR
#        OCI_COMPARTMENT_ID=... scripts/run_measured.sh --preflight-only OUT_DIR
# Never put the key on the command line (shell history, ps).
#
# SPENDS REAL MONEY: provision-cluster.sh creates an ENHANCED OKE cluster and
# a GPU node pool. Teardown runs from an EXIT trap on every exit path
# (success, step failure, INT, TERM, HUP) with signals ignored, and an
# out-of-tree watchdog (own session, started before anything billable)
# takes over if the runner is killed outright or overruns WATCHDOG_SEC.
# Each step has its own hard timeout (PROVISION_STEP_TIMEOUT_SEC,
# DEPLOY_STEP_TIMEOUT_SEC, READY_TIMEOUT_SEC, BENCH_STEP_TIMEOUT_SEC); a step
# past it is stopped and teardown runs. Preflight fails if WATCHDOG_SEC is
# below their sum, unless ALLOW_SHORT_WATCHDOG=yes.
#
# Exit codes:
#   0      bench succeeded AND teardown confirmed clean
#   128+N  ended by signal N (INT 130, TERM 143, HUP 129); teardown confirmed clean
#   1      a step failed, or teardown could not be confirmed (watchdog left armed)
#   2      usage error (nothing started)
#   3      GPU node pool and cluster confirmed deleted, but teardown-cluster.sh
#          reported a possibly orphaned block volume, load balancer or network
#
# The NGC key is copied into a non-exported shell variable at start and
# removed from the environment. Only the deploy step gets it, as an
# environment variable (never argv); its output is passed through a filter
# that redacts the key and any base64 token that decodes to text containing it.
#
# Test-only hooks (never for live use): RUNNER_PREFLIGHT, RUNNER_PROVISION,
# RUNNER_DEPLOY, RUNNER_READY (readiness probe, polled until it exits 0),
# RUNNER_BENCH (called with --out FILE), RUNNER_TEARDOWN, and RUNNER_OKE_CONFIG
# (fixture path for the preflight detectors). Defaults are this repo's files. summary.json records which hooks were set.
# NIMBLE_CLUSTER_INFO (test-only, honoured only together with RUNNER_PROVISION)
# replaces scripts/cluster-info.txt as the file the runner reads.
#
# OUT_DIR may sit inside the repo (docs/runs/...). OCIDs appear only in files
# .gitignore covers there (*.log, .oke_ids). receipt.md is the committable
# artifact: no OCIDs, no IP addresses, no key.
set -euo pipefail
# A dead stdout (closed pane, killed `| tee`) must never kill the runner.
trap '' PIPE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

usage() {
  cat <<'EOF'
Usage: export NGC_API_KEY beforehand (read -rs NGC_API_KEY; export NGC_API_KEY), then
         OCI_COMPARTMENT_ID=... scripts/run_measured.sh OUT_DIR
       OCI_COMPARTMENT_ID=... scripts/run_measured.sh --key-file PATH OUT_DIR
       OCI_COMPARTMENT_ID=... scripts/run_measured.sh --preflight-only OUT_DIR
  Never type the key on the command line: it lands in shell history and ps.
  OUT_DIR           new or empty directory for logs, phases.log and summary.json
  --key-file PATH   read the NGC key from PATH (mode 600 or 400; first line used);
                    overrides NGC_API_KEY; the contents are never logged
  --preflight-only  run only the no-cost preflight checks (real oci calls, read-only);
                    writes preflight.log and phases.log, starts no watchdog, creates
                    nothing, exits with the preflight status; NGC_API_KEY optional

Env (required): OCI_COMPARTMENT_ID, NGC_API_KEY (NGC_CLI_API_KEY accepted) or --key-file
Env (optional): OCI_REGION (us-phoenix-1; also exported as OCI_CLI_REGION),
  OKE_GPU_SHAPE (VM.GPU.A10.1),
  NODE_COUNT (1), CLUSTER_NAME (nimble-oke-cluster), OCI_TENANCY_OCID (for the
  GPU limit query; default OCI_COMPARTMENT_ID), WATCHDOG_SEC (9000; must be >=
  the step-budget sum below unless ALLOW_SHORT_WATCHDOG=yes),
  PROVISION_STEP_TIMEOUT_SEC (3600), DEPLOY_STEP_TIMEOUT_SEC (2400),
  READY_TIMEOUT_SEC (1800), BENCH_STEP_TIMEOUT_SEC (900),
  POLL_SEC (15), CLEANUP_RETRY_SEC (1800),
  TEARDOWN_RETRY_PAUSE_SEC (30), STEP_STOP_WAIT_SEC (900),
  NIM_LOCAL_PORT (empty: a free local port; a busy port is replaced by a free one)
Tools: oci kubectl helm jq python3 curl bc (macOS: caffeinate, if present, keeps
  the laptop from idle-sleeping while the runner and watchdog live)
EOF
}

OUT_DIR=""
WATCHDOG_MODE=0
WD_MAIN_PID=""
PREFLIGHT_ONLY=0
KEY_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --preflight-only) PREFLIGHT_ONLY=1 ;;
    --key-file)
      KEY_FILE="${2:-}"
      [[ -n "${KEY_FILE}" ]] || { usage >&2; exit 2; }
      shift
      ;;
    --watchdog-for)
      # Internal: the runner re-invokes itself in its own session as the
      # out-of-tree watchdog for runner pid $2.
      WATCHDOG_MODE=1
      WD_MAIN_PID="${2:-}"
      [[ "${WD_MAIN_PID}" =~ ^[0-9]+$ ]] || { usage >&2; exit 2; }
      shift
      ;;
    -*) usage >&2; exit 2 ;;
    *)
      [[ -z "${OUT_DIR}" ]] || { usage >&2; exit 2; }
      OUT_DIR="$1"
      ;;
  esac
  shift
done
[[ -n "${OUT_DIR}" ]] || { usage >&2; exit 2; }

# Take the NGC key out of the exported environment at once: no child except
# the deploy step (and its redaction filter) ever sees it.
NGC_KEY_VALUE="${NGC_API_KEY:-${NGC_CLI_API_KEY:-}}"
unset NGC_API_KEY NGC_CLI_API_KEY
[[ "${WATCHDOG_MODE}" == "1" ]] && { NGC_KEY_VALUE=""; KEY_FILE=""; }
# --key-file: the file must be a regular file with mode 600 or 400 (owner
# only). Its contents go into a non-exported variable and are never logged.
if [[ -n "${KEY_FILE}" ]]; then
  [[ -f "${KEY_FILE}" ]] || { echo "ERROR: --key-file ${KEY_FILE}: not a regular file" >&2; exit 2; }
  kf_mode="$(stat -f %Lp "${KEY_FILE}" 2>/dev/null || stat -c %a "${KEY_FILE}" 2>/dev/null || echo unknown)"
  case "${kf_mode}" in
    600|400) ;;
    *) echo "ERROR: --key-file ${KEY_FILE} has mode ${kf_mode}; it must be 600 or 400 (chmod 600 ${KEY_FILE})" >&2
       exit 2 ;;
  esac
  IFS= read -r NGC_KEY_VALUE < "${KEY_FILE}" || true
  NGC_KEY_VALUE="${NGC_KEY_VALUE%$'\r'}"
  [[ -n "${NGC_KEY_VALUE}" ]] || { echo "ERROR: --key-file ${KEY_FILE} is empty" >&2; exit 2; }
  unset kf_mode
fi

if [[ "${WATCHDOG_MODE}" != "1" && -d "${OUT_DIR}" && -n "$(ls -A "${OUT_DIR}" 2>/dev/null)" ]]; then
  echo "ERROR: OUT_DIR ${OUT_DIR} is not empty; use a new directory per run" >&2
  exit 2
fi
mkdir -p "${OUT_DIR}"
OUT_DIR="$(cd "${OUT_DIR}" && pwd)"

OCI_REGION="${OCI_REGION:-us-phoenix-1}"
OKE_GPU_SHAPE="${OKE_GPU_SHAPE:-VM.GPU.A10.1}"
NODE_COUNT="${NODE_COUNT:-1}"
CLUSTER_NAME="${CLUSTER_NAME:-nimble-oke-cluster}"
NODE_POOL_NAME="gpu-node-pool"            # fixed in provision-cluster.sh
NIM_RELEASE="nvidia-nim"                  # fixed in deploy.sh; chart fullname == release
NIM_NAMESPACE="default"                   # fixed in deploy.sh
WATCHDOG_SEC="${WATCHDOG_SEC:-9000}"
# Hard per-step caps. Their sum must fit inside WATCHDOG_SEC (preflight check).
PROVISION_STEP_TIMEOUT_SEC="${PROVISION_STEP_TIMEOUT_SEC:-3600}"
DEPLOY_STEP_TIMEOUT_SEC="${DEPLOY_STEP_TIMEOUT_SEC:-2400}"
READY_TIMEOUT_SEC="${READY_TIMEOUT_SEC:-1800}"
BENCH_STEP_TIMEOUT_SEC="${BENCH_STEP_TIMEOUT_SEC:-900}"
ALLOW_SHORT_WATCHDOG="${ALLOW_SHORT_WATCHDOG:-no}"
POLL_SEC="${POLL_SEC:-15}"
CLEANUP_RETRY_SEC="${CLEANUP_RETRY_SEC:-1800}"
TEARDOWN_RETRY_PAUSE_SEC="${TEARDOWN_RETRY_PAUSE_SEC:-30}"
STEP_STOP_WAIT_SEC="${STEP_STOP_WAIT_SEC:-900}"
CLEANUP_LOCK_WAIT_SEC="${CLEANUP_LOCK_WAIT_SEC:-3600}"
NIM_LOCAL_PORT="${NIM_LOCAL_PORT:-}"
[[ -z "${NIM_LOCAL_PORT}" || "${NIM_LOCAL_PORT}" =~ ^[0-9]+$ ]] \
  || { echo "ERROR: NIM_LOCAL_PORT must be empty or a port number" >&2; exit 2; }
for v in NODE_COUNT WATCHDOG_SEC READY_TIMEOUT_SEC POLL_SEC CLEANUP_RETRY_SEC \
         TEARDOWN_RETRY_PAUSE_SEC STEP_STOP_WAIT_SEC CLEANUP_LOCK_WAIT_SEC \
         PROVISION_STEP_TIMEOUT_SEC DEPLOY_STEP_TIMEOUT_SEC BENCH_STEP_TIMEOUT_SEC; do
  [[ "${!v}" =~ ^[0-9]+$ ]] || { echo "ERROR: ${v} must be a non-negative integer" >&2; exit 2; }
done
STEP_BUDGET_SUM=$(( PROVISION_STEP_TIMEOUT_SEC + DEPLOY_STEP_TIMEOUT_SEC + READY_TIMEOUT_SEC + BENCH_STEP_TIMEOUT_SEC ))
# Every oci call (the runner's own and its children's) targets OCI_REGION, not
# the CLI profile's region; the OCI CLI reads OCI_CLI_REGION.
OCI_CLI_REGION="${OCI_REGION}"
export OCI_REGION OCI_CLI_REGION OKE_GPU_SHAPE NODE_COUNT CLUSTER_NAME WATCHDOG_SEC READY_TIMEOUT_SEC \
       POLL_SEC CLEANUP_RETRY_SEC TEARDOWN_RETRY_PAUSE_SEC STEP_STOP_WAIT_SEC \
       CLEANUP_LOCK_WAIT_SEC NIM_LOCAL_PORT PROVISION_STEP_TIMEOUT_SEC \
       DEPLOY_STEP_TIMEOUT_SEC BENCH_STEP_TIMEOUT_SEC ALLOW_SHORT_WATCHDOG

INFO_FILE="${SCRIPT_DIR}/cluster-info.txt"   # written by provision, read by teardown
if [[ -n "${RUNNER_PROVISION:-}" && -n "${NIMBLE_CLUSTER_INFO:-}" ]]; then
  INFO_FILE="${NIMBLE_CLUSTER_INFO}"          # test-only: fake provision writes here
  export NIMBLE_CLUSTER_INFO
else
  unset NIMBLE_CLUSTER_INFO
fi
PHASES="${OUT_DIR}/phases.log"
WATCHDOG_STOP="${OUT_DIR}/.watchdog_stop"
WATCHDOG_ARMED="${OUT_DIR}/.watchdog_armed"
PROVISION_STARTED="${OUT_DIR}/.provision_started"
CLEANUP_COMPLETE="${OUT_DIR}/CLEANUP_COMPLETE"
BILLABLE_END="${OUT_DIR}/.billable_end"
STEP_PID_FILE="${OUT_DIR}/.step.pid"
PF_PID_FILE="${OUT_DIR}/.pf.pid"
CLEANUP_LOCK_DIR="${OUT_DIR}/.cleanup_lock"
DEPLOY_TMP_MARKER="${OUT_DIR}/.deploy_tmpdir"

# ---------------------------------------------------------------- helpers
now() { date +%s; }
ts() { date -u +%FT%TZ; }
# Console output goes through an external printf: a failed write to a dead
# stdout then cannot linger in bash's buffer and leak into a later file write.
console() { env printf '%s\n' "$*" 2>/dev/null || true; }
note() {
  echo "$(ts) $*" >> "${OUT_DIR}/runner.log"
  console "$(ts) $*"
}
phase() {  # $1 name, $2 START|END, $3 rc
  local line
  line="PHASE $1 $2 $(now) rc=${3:-0}"
  echo "${line}" >> "${PHASES}"
  console "$(ts) ${line}"
}
lib_call() { ( source "${SCRIPT_DIR}/_lib.sh" && "$@" ); }
json_len() {  # prints the length of a JSON list on stdin ("" counts as 0)
  python3 -c 'import json,sys; s=sys.stdin.read().strip(); print(len(json.loads(s)) if s else 0)'
}
is_running() {  # true if pid exists and is not a zombie
  local st
  [[ -n "${1:-}" ]] || return 1
  st="$(ps -p "$1" -o stat= 2>/dev/null)" || return 1
  st="${st// /}"
  [[ -n "${st}" && "${st}" != Z* ]]
}
descendants() {  # all descendant pids of $1, one per line
  local table queue p c
  table="$(ps -A -o pid= -o ppid= 2>/dev/null)" || return 0
  queue="$1"
  while [[ -n "${queue}" ]]; do
    p="${queue%% *}"
    if [[ "${queue}" == *" "* ]]; then queue="${queue#* }"; else queue=""; fi
    for c in $(echo "${table}" | awk -v p="${p}" '$2==p {print $1}'); do
      echo "${c}"
      queue="${queue:+${queue} }${c}"
    done
  done
}
# Stop a process tree: TERM to the root and every descendant, wait up to $2
# seconds for all of them, then KILL what is left. $3 = label for the log.
stop_tree() {
  local root="$1" wait_sec="$2" label="$3" pids p t0 alive
  is_running "${root}" || return 0
  pids="${root} $(descendants "${root}" | tr '\n' ' ')"
  note "stopping ${label} (pids: ${pids% })"
  for p in ${pids}; do kill -TERM "${p}" 2>/dev/null || true; done
  t0="$(now)"
  while :; do
    alive=""
    for p in ${pids}; do is_running "${p}" && alive="${alive} ${p}"; done
    [[ -z "${alive}" ]] && break
    if (( $(now) - t0 >= wait_sec )); then
      note "${label} still running after ${wait_sec}s (pids:${alive}); sending KILL"
      for p in ${alive}; do kill -KILL "${p}" 2>/dev/null || true; done
      break
    fi
    sleep 1
  done
}
info_get() {  # read KEY from cluster-info.txt (or the OUT_DIR snapshot) without sourcing it
  local v=""
  [[ -f "${INFO_FILE}" ]] && v="$(sed -n "s/^$1=//p" "${INFO_FILE}" | tail -1)"
  [[ -z "${v}" && -f "${OUT_DIR}/.oke_ids" ]] && v="$(sed -n "s/^$1=//p" "${OUT_DIR}/.oke_ids" | tail -1)"
  echo "${v}"
}
effective_shape() { local s; s="$(info_get GPU_SHAPE)"; echo "${s:-${OKE_GPU_SHAPE}}"; }

# Kube context pin: provision-cluster.sh records KUBE_CONTEXT=<name> in
# cluster-info.txt. When present, the runner's own kubectl calls use
# --context and helm children get HELM_KUBECONTEXT; deploy.sh reads the same
# file itself. The user's current-context is never changed.
KCTX_ARGS=()
load_kube_context() {
  local c
  c="$(info_get KUBE_CONTEXT)"
  KCTX_ARGS=()
  if [[ -n "${c}" ]]; then
    KCTX_ARGS=(--context "${c}")
    export HELM_KUBECONTEXT="${c}"
    note "kube context pinned to ${c} (from cluster-info.txt)"
  fi
}

port_is_free() {  # $1 port: true if 127.0.0.1:$1 can be bound now
  python3 -c 'import socket,sys; s=socket.socket(); s.bind(("127.0.0.1", int(sys.argv[1]))); s.close()' "$1" 2>/dev/null
}
free_local_port() {  # an unused 127.0.0.1 TCP port, chosen by the kernel
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

# macOS: hold an idle-sleep assertion while pid $1 lives (caffeinate -i -w),
# so laptop sleep cannot stall a teardown. No-op where caffeinate is absent.
hold_awake() {
  [[ "$(uname -s 2>/dev/null)" == "Darwin" ]] || return 0
  command -v caffeinate >/dev/null 2>&1 || return 0
  caffeinate -i -w "$1" < /dev/null > /dev/null 2>&1 &
  return 0
}

# The deploy step runs with TMPDIR set to a private directory the runner
# creates; any file left there by a stopped deploy (helm temp files, older
# deploy.sh values files) is removed by the runner or the watchdog.
remove_deploy_tmp() {
  local d=""
  [[ -f "${DEPLOY_TMP_MARKER}" ]] && d="$(cat "${DEPLOY_TMP_MARKER}" 2>/dev/null || true)"
  case "${d}" in
    */nimble-deploy.*) [[ -d "${d}" ]] && rm -rf "${d}" ;;
  esac
  rm -f "${DEPLOY_TMP_MARKER}"
  return 0
}

# mkdir lock shared by the runner trap and the watchdog, so their teardowns
# never overlap. A dead owner's lock (no longer a run_measured process) is broken.
acquire_cleanup_lock() {  # $1 = owner "role:pid"
  local me="$1" start cur pid
  start="$(now)"
  while :; do
    if mkdir "${CLEANUP_LOCK_DIR}" 2>/dev/null; then
      echo "${me}" > "${CLEANUP_LOCK_DIR}/owner"
      return 0
    fi
    cur="$(cat "${CLEANUP_LOCK_DIR}/owner" 2>/dev/null || true)"
    [[ "${cur}" == "${me}" ]] && return 0
    pid="${cur##*:}"
    if [[ -n "${cur}" && "${pid}" =~ ^[0-9]+$ ]] \
       && ! ps -p "${pid}" -o command= 2>/dev/null | grep -q "run_measured"; then
      rm -rf "${CLEANUP_LOCK_DIR}"
      continue
    fi
    if (( $(now) - start >= CLEANUP_LOCK_WAIT_SEC )); then
      note "cleanup lock wait timed out (held by ${cur:-unknown}); proceeding"
      return 0
    fi
    sleep 1
  done
}
release_cleanup_lock() {
  local cur
  cur="$(cat "${CLEANUP_LOCK_DIR}/owner" 2>/dev/null || true)"
  [[ "${cur}" == "$1" ]] && rm -rf "${CLEANUP_LOCK_DIR}"
  return 0
}

# Redaction filter for the deploy step's output (the only step that holds
# the key). Ignores INT/TERM/HUP and exits at EOF, so it outlives the writer.
# shellcheck disable=SC2016
REDACT_PY='
# nimble_redact_filter
import base64, binascii, os, re, signal, sys
for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(s, signal.SIG_IGN)
kb = os.environ.pop("NIMBLE_REDACT_VALUE", "").encode()
tok = re.compile(rb"[A-Za-z0-9+/_-]{12,}={0,2}")
def hit(t):
    p = t + b"=" * (-len(t) % 4)
    for dec in (base64.b64decode, base64.urlsafe_b64decode):
        try:
            if kb in dec(p):
                return True
        except (binascii.Error, ValueError):
            pass
    return False
out = sys.stdout.buffer
for line in sys.stdin.buffer:
    if kb:
        line = line.replace(kb, b"[REDACTED]")
        line = tok.sub(lambda m: b"[REDACTED-B64]" if hit(m.group(0)) else m.group(0), line)
    try:
        out.write(line)
        out.flush()
    except OSError:
        pass
'

STEP_PID=""
STEP_TIMEOUT=0   # hard cap in seconds for the next run_step (0 = none)
# run_step NAME CMD [ARGS...]: run CMD in the background (so a signal to the
# runner is handled at once, not after a 20-minute step), stdin /dev/null,
# output appended to OUT_DIR/NAME.log; wait for it and return its status.
# With STEP_TIMEOUT > 0 the step tree is stopped after that many seconds and
# run_step returns 124.
run_step() {
  local name="$1" rc=0 limit="${STEP_TIMEOUT}" t0 timed_out=0
  STEP_TIMEOUT=0
  shift
  local log="${OUT_DIR}/${name}.log"
  case "${name}" in
    deploy)
      local dtmp
      dtmp="$(mktemp -d "${TMPDIR:-/tmp}/nimble-deploy.XXXXXX")" || return 1
      echo "${dtmp}" > "${DEPLOY_TMP_MARKER}"
      ( TMPDIR="${dtmp}" NGC_API_KEY="${NGC_KEY_VALUE}" CONFIRM_COST=yes "$@" < /dev/null 2>&1 \
          | NIMBLE_REDACT_VALUE="${NGC_KEY_VALUE}" python3 -c "${REDACT_PY}" >> "${log}" ) &
      ;;
    provision)
      CONFIRM_COST=yes "$@" < /dev/null >> "${log}" 2>&1 &
      ;;
    *)
      "$@" < /dev/null >> "${log}" 2>&1 &
      ;;
  esac
  STEP_PID=$!
  echo "${STEP_PID} ${name}" > "${STEP_PID_FILE}"
  if (( limit > 0 )); then
    t0="$(now)"
    while is_running "${STEP_PID}"; do
      if (( $(now) - t0 >= limit )); then
        timed_out=1
        note "step ${name} exceeded its hard timeout of ${limit}s; stopping it"
        echo "$(ts) RUNNER: step ${name} exceeded its hard timeout of ${limit}s; stopped" >> "${log}"
        stop_tree "${STEP_PID}" "${STEP_STOP_WAIT_SEC}" "timeout: step ${name}"
        break
      fi
      isleep 1
    done
  fi
  wait "${STEP_PID}" || rc=$?
  [[ "${timed_out}" == "1" ]] && rc=124
  STEP_PID=""
  rm -f "${STEP_PID_FILE}"
  [[ "${name}" == "deploy" ]] && remove_deploy_tmp
  return "${rc}"
}

stop_running_step() {  # $1 = who; stops a step still running (orphaned or interrupted)
  local pid="" name=""
  [[ -f "${STEP_PID_FILE}" ]] && read -r pid name < "${STEP_PID_FILE}"
  if [[ -n "${pid}" ]] && is_running "${pid}"; then
    stop_tree "${pid}" "${STEP_STOP_WAIT_SEC}" "$1: step ${name}"
    wait "${pid}" 2>/dev/null || true
  fi
  rm -f "${STEP_PID_FILE}"
  remove_deploy_tmp
  pid=""
  [[ -f "${PF_PID_FILE}" ]] && read -r pid < "${PF_PID_FILE}"
  if [[ -n "${pid}" ]] && is_running "${pid}" \
     && ps -p "${pid}" -o command= 2>/dev/null | grep -q "port-forward"; then
    stop_tree "${pid}" 5 "$1: kubectl port-forward"
  fi
  rm -f "${PF_PID_FILE}"
}

# ------------------------------------------------------ teardown + verify
run_teardown_once() {
  local rc=0
  if [[ -n "${RUNNER_TEARDOWN:-}" ]]; then
    "${RUNNER_TEARDOWN}" < /dev/null >> "${OUT_DIR}/teardown.log" 2>&1 || rc=$?
  else
    FORCE=yes "${SCRIPT_DIR}/teardown-cluster.sh" < /dev/null >> "${OUT_DIR}/teardown.log" 2>&1 || rc=$?
  fi
  return "${rc}"
}

# Independent check: no non-DELETED cluster named CLUSTER_NAME and no
# non-DELETED node pool in the recorded cluster. Never "clean when unsure".
verify_clean() {
  local out n cid
  echo "$(ts) oci ce cluster list --name ${CLUSTER_NAME}"
  out="$(oci ce cluster list --compartment-id "${OCI_COMPARTMENT_ID}" --name "${CLUSTER_NAME}" --all \
          --region "${OCI_REGION}" \
          --query "data[?\"lifecycle-state\"!='DELETED'].id" --raw-output)" \
    || { echo "cluster list FAILED: cannot confirm"; return 1; }
  n="$(printf '%s' "${out}" | json_len)" || { echo "cluster list output unparseable"; return 1; }
  echo "non-DELETED clusters named ${CLUSTER_NAME}: ${n}"
  [[ "${n}" == "0" ]] || return 1
  cid="$(info_get CLUSTER_ID)"
  if [[ -n "${cid}" ]]; then
    echo "$(ts) oci ce node-pool list --cluster-id <recorded cluster>"
    out="$(oci ce node-pool list --compartment-id "${OCI_COMPARTMENT_ID}" --cluster-id "${cid}" --all \
            --region "${OCI_REGION}" \
            --query "data[?\"lifecycle-state\"!='DELETED'].id" --raw-output)" \
      || { echo "node-pool list FAILED: cannot confirm"; return 1; }
    n="$(printf '%s' "${out}" | json_len)" || { echo "node-pool list output unparseable"; return 1; }
    echo "non-DELETED node pools in the recorded cluster: ${n}"
    [[ "${n}" == "0" ]] || return 1
  fi
  return 0
}

TD_RESULT="not-needed"   # not-needed | clean | partial | failed | no-info
TD_RC=""
TD_ATTEMPTS=0
VERIFY_OK=0
cleanup_sequence() {  # $1 = runner | watchdog
  local who="$1" start rc
  if [[ -f "${CLEANUP_COMPLETE}" ]]; then
    TD_RESULT="clean"; VERIFY_OK=1
    note "${who}: teardown already confirmed clean earlier"
    return 0
  fi
  phase teardown START 0
  start="$(now)"
  if [[ -z "${RUNNER_TEARDOWN:-}" && ! -f "${INFO_FILE}" ]]; then
    TD_RESULT="no-info"; TD_RC=""
    note "${who}: no ${INFO_FILE}; provision-cluster.sh recorded nothing; verifying by name only"
  else
    while :; do
      TD_ATTEMPTS=$((TD_ATTEMPTS + 1))
      note "${who}: teardown attempt ${TD_ATTEMPTS} start"
      rc=0
      run_teardown_once || rc=$?
      TD_RC="${rc}"
      note "${who}: teardown attempt ${TD_ATTEMPTS} exit ${rc}"
      if [[ "${rc}" == "0" ]]; then TD_RESULT="clean"; break; fi
      if [[ "${rc}" == "2" ]]; then TD_RESULT="partial"; break; fi
      TD_RESULT="failed"
      if (( $(now) - start >= CLEANUP_RETRY_SEC && TD_ATTEMPTS >= 2 )); then break; fi
      sleep "${TEARDOWN_RETRY_PAUSE_SEC}"
    done
  fi
  phase teardown END "${TD_RC:-0}"
  phase verify-clean START 0
  VERIFY_OK=0
  if verify_clean >> "${OUT_DIR}/verify-clean.log" 2>&1; then VERIFY_OK=1; fi
  phase verify-clean END $((1 - VERIFY_OK))
  if [[ "${VERIFY_OK}" == "1" && "${TD_RESULT}" != "failed" ]]; then
    now > "${BILLABLE_END}"
    if [[ "${TD_RESULT}" == "clean" || "${TD_RESULT}" == "no-info" ]]; then
      echo "verified clean by ${who} at $(ts)" > "${CLEANUP_COMPLETE}"
    fi
  fi
}

manual_commands() {
  local cid npid
  cid="$(info_get CLUSTER_ID)"
  npid="$(info_get NODE_POOL_ID)"
  echo "Delete the GPU node pool first, then the cluster (OCI CLI, region ${OCI_REGION}):"
  echo "  oci ce node-pool list --compartment-id \"\$OCI_COMPARTMENT_ID\" --name ${NODE_POOL_NAME} --region ${OCI_REGION}"
  echo "  oci ce node-pool delete --node-pool-id ${npid:-<NODE_POOL_OCID>} --region ${OCI_REGION} --force --wait-for-state SUCCEEDED --wait-for-state FAILED"
  echo "  oci ce cluster list --compartment-id \"\$OCI_COMPARTMENT_ID\" --name ${CLUSTER_NAME} --region ${OCI_REGION}"
  echo "  oci ce cluster delete --cluster-id ${cid:-<CLUSTER_OCID>} --region ${OCI_REGION} --force --wait-for-state SUCCEEDED --wait-for-state FAILED"
  echo "Then remove the network and leftovers: OCI_REGION=${OCI_REGION} FORCE=yes scripts/teardown-cluster.sh"
}
partial_commands() {
  echo "GPU node pool and cluster are deleted (GPU billing stopped). Check for orphans:"
  echo "  oci bv volume list --region ${OCI_REGION} --compartment-id \"\$OCI_COMPARTMENT_ID\" --lifecycle-state AVAILABLE"
  echo "  oci lb load-balancer list --region ${OCI_REGION} --compartment-id \"\$OCI_COMPARTMENT_ID\""
  echo "  oci network vcn list --region ${OCI_REGION} --compartment-id \"\$OCI_COMPARTMENT_ID\" --display-name nimble-oke-vcn"
  echo "scripts/cluster-info.txt is kept; re-run: FORCE=yes scripts/teardown-cluster.sh"
}

write_summary() {  # $1 = runner | watchdog, $2 = runner exit code ("" if unknown)
  local hourly="" hooks="" h
  hourly="$(lib_call estimate_hourly_cost "${NODE_COUNT}" "$(effective_shape)" 2>/dev/null)" || hourly=""
  for h in RUNNER_PREFLIGHT RUNNER_PROVISION RUNNER_DEPLOY RUNNER_READY RUNNER_BENCH RUNNER_TEARDOWN; do
    [[ -n "${!h:-}" ]] && hooks="${hooks}${h},"
  done
  S_WHO="$1" S_RC="$2" S_HOURLY="${hourly}" S_HOOKS="${hooks%,}" \
  S_SHAPE="$(effective_shape)" S_SHAPE_REQ="${OKE_GPU_SHAPE}" S_REGION="${OCI_REGION}" \
  S_NODES="${NODE_COUNT}" S_TD_RESULT="${TD_RESULT}" S_TD_RC="${TD_RC}" \
  S_TD_ATTEMPTS="${TD_ATTEMPTS}" S_VERIFY="${VERIFY_OK}" S_SIGNAL="${SIGNAL_NAME:-}" \
  S_VALUES="${REPO_ROOT}/helm/values.yaml" \
  python3 - "${OUT_DIR}" <<'PY' || note "WARNING: summary.json could not be written"
import json, os, re, sys, time
out = sys.argv[1]
E = os.environ
def rd(name):
    try:
        with open(os.path.join(out, name)) as f:
            return f.read().strip()
    except OSError:
        return ""
def num(s):
    try:
        return int(s)
    except (TypeError, ValueError):
        return None
secs, rcs, open_start, order = {}, {}, {}, []
for line in rd("phases.log").splitlines():
    m = re.match(r"PHASE (\S+) (START|END) (\d+) rc=(-?\d+)$", line)
    if not m:
        continue
    name, kind, t, rc = m.group(1), m.group(2), int(m.group(3)), int(m.group(4))
    if name not in order:
        order.append(name)
    if kind == "START":
        open_start[name] = t
    elif name in open_start:
        secs[name] = secs.get(name, 0) + t - open_start.pop(name)
        rcs[name] = rc
image = None
try:
    txt = open(E["S_VALUES"]).read()
    blk = re.search(r"^image:[^\n]*\n((?:[ \t]+[^\n]*\n?)+)", txt, re.M)
    if blk:
        g = lambda k: (re.search(r"^\s+%s:\s*\"?([^\"\s#]+)" % k, blk.group(1), re.M) or [None, None])[1]
        reg, repo, tag = g("registry"), g("repository"), g("tag")
        if repo:
            image = "%s%s%s" % (reg + "/" if reg else "", repo, ":" + tag if tag else "")
except OSError:
    pass
bench = None
try:
    bench = json.loads(rd("bench.json")) if rd("bench.json") else None
except ValueError:
    bench = {"error": "bench.json unparseable"}
b_start, b_end = num(rd(".provision_started")), num(rd(".billable_end"))
billable = (b_end - b_start) if (b_start and b_end) else None
so_far = (int(time.time()) - b_start) if (b_start and not b_end) else None
hourly = None
try:
    hourly = float(E.get("S_HOURLY", "")) if E.get("S_HOURLY") else None
except ValueError:
    pass
cost_secs = billable if billable is not None else so_far
prev = {}
try:
    prev = json.loads(rd("summary.json")) if rd("summary.json") else {}
except ValueError:
    pass
rc = num(E.get("S_RC"))
if rc is None:
    rc = prev.get("runner_exit_code")
hooks = [h for h in E.get("S_HOOKS", "").split(",") if h]
s = {
    "live_run": not hooks,
    "test_hooks": hooks,
    "written_by": E["S_WHO"],
    "runner_exit_code": rc,
    "signal": E.get("S_SIGNAL") or prev.get("signal") or None,
    "shape": E["S_SHAPE"],
    "shape_requested": E["S_SHAPE_REQ"],
    "region": E["S_REGION"],
    "node_count": num(E["S_NODES"]),
    "image": image,
    "k8s_version": rd("k8s-version.txt") or None,
    "phase_order": order,
    "phase_seconds": secs,
    "phase_rc": rcs,
    "phases_incomplete": sorted(open_start),
    "billable_start_epoch": b_start,
    "billable_end_epoch": b_end,
    "billing_stop_confirmed": billable is not None,
    "billable_seconds": billable,
    "billable_seconds_so_far_unconfirmed": so_far,
    "hourly_rate_usd": hourly,
    "estimated_cost_usd": round(hourly * cost_secs / 3600.0, 4) if (hourly is not None and cost_secs is not None) else None,
    "cost_note": "rate from scripts/_lib.sh estimate_hourly_cost: GPU and enhanced-cluster rates verified there; LB and storage are estimates (unverified)",
    "bench_ok": rcs.get("bench") == 0 and isinstance(bench, dict) and "error" not in bench,
    "bench": bench,
    "teardown": {
        "result": E["S_TD_RESULT"],
        "last_exit_code": num(E.get("S_TD_RC")),
        "attempts": num(E.get("S_TD_ATTEMPTS")),
        "verify_clean": E.get("S_VERIFY") == "1",
        "cleanup_complete_marker": rd("CLEANUP_COMPLETE") or None,
        "gpu_billing_stopped_possible_orphans": E["S_TD_RESULT"] == "partial",
    },
}
tmp = os.path.join(out, ".summary.json.tmp")
with open(tmp, "w") as f:
    json.dump(s, f, indent=2)
    f.write("\n")
os.replace(tmp, os.path.join(out, "summary.json"))

# receipt.md: the committable artifact. Whitelisted fields only, then a scrub
# for OCIDs and IPv4 addresses as a second line of defence.
td_text = {
    "clean": "clean: GPU node pool, cluster and network deleted; verified",
    "partial": "PARTIAL (teardown exit 2): GPU billing stopped (node pool and cluster deleted); "
               "a block volume, load balancer or network may be orphaned - check the OCI console",
    "failed": "FAILED: teardown not confirmed; GPU billing may continue",
    "no-info": "no cluster-info recorded; verified by cluster name only",
    "not-needed": "not needed: nothing billable was started",
}.get(s["teardown"]["result"], s["teardown"]["result"])
def fmt(v):
    return "n/a" if v is None else str(v)
L = ["# Measured run receipt", ""]
L.append("- Date (UTC): %s" % time.strftime("%Y-%m-%d %H:%M", time.gmtime(b_start or time.time())))
L.append("- Live run: %s%s" % ("yes" if s["live_run"] else "no",
         "" if s["live_run"] else " (test hooks: %s)" % ", ".join(hooks)))
L.append("- Region: %s" % s["region"])
L.append("- Shape: %s x %s" % (s["shape"], fmt(s["node_count"])))
L.append("- Image: %s" % fmt(image))
L.append("- Kubernetes version: %s" % fmt(s["k8s_version"]))
L.append("- Runner exit code: %s" % fmt(rc))
L += ["", "## Phases (seconds)", ""]
for name in order:
    L.append("- %s: %s (rc %s)" % (name, fmt(secs.get(name)), fmt(rcs.get(name))))
L += ["", "## Cost", ""]
L.append("- Billable seconds (provision start to verified teardown): %s" % fmt(billable))
if billable is None and so_far is not None:
    L.append("- Billing stop NOT confirmed; seconds so far: %s" % so_far)
L.append("- Hourly rate (USD): %s" % fmt(hourly))
L.append("- Estimated cost (USD): %s" % fmt(s["estimated_cost_usd"]))
L.append("- Rate basis: %s" % s["cost_note"])
L += ["", "## Bench", ""]
if isinstance(bench, dict) and "error" not in bench:
    for k in ("model", "n_requested", "n_ok", "ttfr_s", "tokens_per_s"):
        if k in bench:
            L.append("- %s: %s" % (k, json.dumps(bench[k], sort_keys=True)))
else:
    L.append("- no bench result (%s)" % ("unparseable" if bench else "not run"))
L += ["", "## Teardown", ""]
L.append("- Result: %s" % td_text)
L.append("- Last teardown exit code: %s; attempts: %s; verify-clean: %s" % (
    fmt(s["teardown"]["last_exit_code"]), fmt(s["teardown"]["attempts"]),
    "yes" if s["teardown"]["verify_clean"] else "no"))
txt = "\n".join(L) + "\n"
txt = re.sub(r"ocid1\.[^\s\"',)]*", "[ocid-redacted]", txt)
txt = re.sub(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", "[ip-redacted]", txt)
tmp = os.path.join(out, ".receipt.md.tmp")
with open(tmp, "w") as f:
    f.write(txt)
os.replace(tmp, os.path.join(out, "receipt.md"))
PY
}

# ------------------------------------------------------------- watchdog
main_alive() {
  kill -0 "${WD_MAIN_PID}" 2>/dev/null \
    && ps -p "${WD_MAIN_PID}" -o command= 2>/dev/null | grep -q "run_measured"
}
wd_final() {  # the last line of watchdog.log states the outcome
  echo "$(ts) WATCHDOG FINAL: $*"
  exit 0
}
wd_standdown() {
  local why
  why="$(cat "${WATCHDOG_STOP}" 2>/dev/null || true)"
  case "${why}" in
    clean*) wd_final "cleanup completed by runner (teardown confirmed clean); watchdog stood down" ;;
    partial*) wd_final "cleanup completed with warnings by runner: GPU node pool and cluster deleted; block volume, load balancer or network may be orphaned (see trap.log)" ;;
    not-needed*) wd_final "cleanup completed: nothing billable was started; watchdog stood down" ;;
    *) wd_final "stop file present (${why:-empty}); watchdog stood down" ;;
  esac
}
watchdog_main() {
  trap '' HUP INT
  local me="watchdog:$$" start reason g
  echo "$$" > "${OUT_DIR}/watchdog.pid"
  hold_awake "$$"
  : > "${WATCHDOG_ARMED}"
  echo "$(ts) watchdog armed: runner pid ${WD_MAIN_PID}, deadline ${WATCHDOG_SEC}s"
  start="$(now)"
  while :; do
    [[ -f "${WATCHDOG_STOP}" ]] && wd_standdown
    if ! main_alive; then
      sleep 2   # a clean exit writes the stop file just before it ends
      [[ -f "${WATCHDOG_STOP}" ]] && wd_standdown
      main_alive && continue
      reason="runner pid ${WD_MAIN_PID} ended without a verified-clean marker"
      break
    fi
    if (( $(now) - start >= WATCHDOG_SEC )); then
      echo "$(ts) deadline ${WATCHDOG_SEC}s reached; sending TERM to runner pid ${WD_MAIN_PID}"
      kill -TERM "${WD_MAIN_PID}" 2>/dev/null || true
      g="$(now)"
      # The runner's trap may be mid-teardown; give it its full budget.
      while main_alive && (( $(now) - g < CLEANUP_RETRY_SEC + STEP_STOP_WAIT_SEC + 600 )); do
        [[ -f "${WATCHDOG_STOP}" ]] && wd_standdown
        sleep 1
      done
      [[ -f "${WATCHDOG_STOP}" ]] && wd_standdown
      reason="deadline"
      break
    fi
    sleep 1
  done
  echo "$(ts) TAKEOVER: ${reason}"
  acquire_cleanup_lock "${me}"
  [[ -f "${WATCHDOG_STOP}" ]] && { release_cleanup_lock "${me}"; wd_standdown; }
  stop_running_step watchdog
  if [[ ! -f "${PROVISION_STARTED}" ]]; then
    release_cleanup_lock "${me}"
    TD_RESULT="not-needed"
    write_summary watchdog ""
    wd_final "cleanup completed: nothing billable was started"
  fi
  cleanup_sequence watchdog
  release_cleanup_lock "${me}"
  write_summary watchdog ""
  if [[ "${VERIFY_OK}" == "1" && ( "${TD_RESULT}" == "clean" || "${TD_RESULT}" == "no-info" ) ]]; then
    wd_final "cleanup completed by watchdog (teardown confirmed clean)"
  elif [[ "${VERIFY_OK}" == "1" && "${TD_RESULT}" == "partial" ]]; then
    partial_commands
    wd_final "cleanup completed with warnings by watchdog: GPU node pool and cluster deleted; orphans possible (commands above)"
  fi
  echo "============================================================"
  echo "TEARDOWN NOT CONFIRMED. GPU BILLING MAY CONTINUE."
  manual_commands
  echo "============================================================"
  wd_final "cleanup NOT completed (teardown result ${TD_RESULT}, verify_clean=${VERIFY_OK}); run the commands above"
}

if [[ "${WATCHDOG_MODE}" == "1" ]]; then
  watchdog_main
fi

# --------------------------------------------------------------- on_exit
RUN_OK=0
ON_EXIT_RAN=0
SIGNAL_NAME=""
PF_PID=""
WATCHDOG_PID=""
on_exit() {
  local exit_status=$?
  set +e
  trap '' INT TERM HUP PIPE
  [[ "${ON_EXIT_RAN}" == "1" ]] && exit "${exit_status}"
  ON_EXIT_RAN=1
  # From here the trap talks only to files: stdout may be a dead pane or pipe.
  # fd 4 keeps the original stderr for the final report.
  exec 4>&2
  exec >> "${OUT_DIR}/trap.log" 2>&1 < /dev/null
  note "exit path: status=${exit_status} signal=${SIGNAL_NAME:-none} bench_ok=${RUN_OK}"
  NGC_KEY_VALUE=""

  stop_running_step runner
  local final="${exit_status}"
  if [[ -f "${PROVISION_STARTED}" ]]; then
    note "teardown running -- signals ignored, do not interrupt"
    acquire_cleanup_lock "runner:$$"
    cleanup_sequence runner
    release_cleanup_lock "runner:$$"
  fi

  if [[ "${TD_RESULT}" == "not-needed" ]] \
     || [[ "${VERIFY_OK}" == "1" && ( "${TD_RESULT}" == "clean" || "${TD_RESULT}" == "no-info" ) ]]; then
    if [[ "${exit_status}" != "0" ]]; then final="${exit_status}"
    elif [[ "${RUN_OK}" == "1" ]]; then final=0
    else final=1
    fi
  elif [[ "${VERIFY_OK}" == "1" && "${TD_RESULT}" == "partial" ]]; then
    final=3
  else
    final=1
  fi

  local cluster_gone=0 stop_reason="${TD_RESULT}"
  [[ "${TD_RESULT}" == "not-needed" ]] && cluster_gone=1
  [[ "${VERIFY_OK}" == "1" && "${TD_RESULT}" != "failed" ]] && cluster_gone=1
  [[ "${TD_RESULT}" == "no-info" ]] && stop_reason="clean"
  if [[ "${cluster_gone}" == "1" ]]; then
    echo "${stop_reason}" > "${WATCHDOG_STOP}"
    if [[ -n "${WATCHDOG_PID}" ]]; then
      local i=0
      while is_running "${WATCHDOG_PID}" && (( i < 10 )); do sleep 1; i=$((i + 1)); done
      is_running "${WATCHDOG_PID}" && kill "${WATCHDOG_PID}" 2>/dev/null
    fi
  fi
  write_summary runner "${final}"

  if [[ "${TD_RESULT}" == "partial" && "${VERIFY_OK}" == "1" ]]; then
    echo "============================================================"
    partial_commands
    echo "============================================================"
  elif [[ "${cluster_gone}" != "1" ]]; then
    echo "============================================================"
    echo "TEARDOWN COULD NOT BE CONFIRMED CLEAN. GPU BILLING MAY CONTINUE."
    echo "WATCHDOG LEFT ARMED (pid ${WATCHDOG_PID:-unknown}); it retries teardown now."
    echo "Follow it: tail -f ${OUT_DIR}/watchdog.log"
    manual_commands
    echo "============================================================"
  fi
  note "runner exit ${final}; logs in ${OUT_DIR}"
  cat "${OUT_DIR}/trap.log" >&4 2>/dev/null || true
  exit "${final}"
}

# ---------------------------------------------------------- preflight
# Each check prints "check: X", then "ok: X" or a "FAIL: ..." line.
# RUNNER_OKE_CONFIG (test hook) points the detectors at a fixture copy of
# oke-optimized-config.sh; the default is the file provision-cluster.sh sources.
default_preflight() {
  local t gpus need eff ad_out ad avail img lim_cid cid k8s opts fail=0
  local cfg="${RUNNER_OKE_CONFIG:-${SCRIPT_DIR}/oke-optimized-config.sh}"
  echo "check: required tools"
  for t in oci kubectl helm jq python3 curl bc; do
    command -v "${t}" >/dev/null 2>&1 || { echo "FAIL: required tool not found: ${t}"; fail=1; }
  done
  [[ "${fail}" == "0" ]] || return 1
  echo "ok: required tools"
  if [[ -n "${NGC_KEY_VALUE}" ]]; then
    echo "ok: NGC_API_KEY set"
  elif [[ "${PREFLIGHT_ONLY}" == "1" ]]; then
    echo "SKIPPED: NGC_API_KEY check (--preflight-only; a full run requires it)"
  else
    echo "FAIL: NGC_API_KEY not set"; return 1
  fi
  echo "check: shape ${OKE_GPU_SHAPE} supported"
  gpus="$(lib_call get_shape_gpu_count "${OKE_GPU_SHAPE}")" || { echo "FAIL: unsupported shape ${OKE_GPU_SHAPE}"; return 1; }
  need=$((gpus * NODE_COUNT))
  echo "ok: shape ${OKE_GPU_SHAPE} supported (${need} GPU(s) for ${NODE_COUNT} node(s))"
  # provision-cluster.sh derives its shape after sourcing oke-optimized-config.sh.
  echo "check: provision-cluster.sh would create the requested shape"
  # shellcheck source=./oke-optimized-config.sh
  eff="$( ( source "${cfg}" >/dev/null 2>&1; echo "${OKE_GPU_SHAPE}" ) )"
  if [[ "${eff}" != "${OKE_GPU_SHAPE}" ]]; then
    echo "FAIL: provision-cluster.sh would create shape '${eff}', not the requested '${OKE_GPU_SHAPE}'"
    echo "      (oke-optimized-config.sh sets readonly OKE_GPU_SHAPE, overriding the environment)"
    return 1
  fi
  echo "ok: provision-cluster.sh would create the requested shape"
  echo "check: helm chart present"
  [[ -f "${REPO_ROOT}/helm/Chart.yaml" && -f "${REPO_ROOT}/helm/values.yaml" ]] || { echo "FAIL: helm chart missing"; return 1; }
  echo "ok: helm chart present"
  echo "check: no stale cluster-info.txt"
  if [[ -f "${INFO_FILE}" ]]; then
    echo "FAIL: ${INFO_FILE} exists from an earlier run; run 'FORCE=yes scripts/teardown-cluster.sh' first"
    return 1
  fi
  echo "ok: no stale cluster-info.txt"
  echo "check: oci auth (oci iam region list)"
  oci iam region list >/dev/null || { echo "FAIL: oci CLI not configured or credentials invalid"; return 1; }
  echo "ok: oci auth"
  echo "check: pinned Kubernetes version is offered by OKE in ${OCI_REGION}"
  k8s="${K8S_VERSION:-$(sed -n 's/.*K8S_VERSION:-\(v[0-9][0-9.]*\)}.*/\1/p' "${SCRIPT_DIR}/provision-cluster.sh" | head -1)}"
  [[ -n "${k8s}" ]] || { echo "FAIL: cannot read the pinned Kubernetes version (K8S_VERSION) from provision-cluster.sh"; return 1; }
  opts="$(oci ce cluster-options get --cluster-option-id all --region "${OCI_REGION}")" \
    || { echo "FAIL: oci ce cluster-options get failed"; return 1; }
  printf '%s' "${opts}" | python3 -c '
import json, sys
d = json.load(sys.stdin)
d = d.get("data", d)
sys.exit(0 if sys.argv[1] in (d.get("kubernetes-versions") or []) else 1)' "${k8s}" \
    || { echo "FAIL: Kubernetes ${k8s} (pinned in provision-cluster.sh) is not offered by OKE in ${OCI_REGION}"; return 1; }
  echo "ok: Kubernetes ${k8s} offered"
  echo "check: no existing cluster named ${CLUSTER_NAME}"
  cid="$(lib_call oci_find_cluster_id "${OCI_COMPARTMENT_ID}" "${CLUSTER_NAME}")" || { echo "FAIL: cluster list failed"; return 1; }
  [[ -z "${cid}" ]] || { echo "FAIL: a cluster named ${CLUSTER_NAME} already exists in the compartment"; return 1; }
  echo "ok: no existing cluster named ${CLUSTER_NAME}"
  echo "check: availability-domain helper returns one line"
  # shellcheck source=./oke-optimized-config.sh
  ad_out="$( ( source "${cfg}" >/dev/null 2>&1
               get_oke_availability_domain "${OCI_COMPARTMENT_ID}" "${OCI_REGION}" ) 2>/dev/null )" \
    || { echo "FAIL: availability-domain lookup failed"; return 1; }
  if [[ -z "${ad_out}" || "$(printf '%s\n' "${ad_out}" | wc -l | tr -d ' ')" != "1" ]]; then
    echo "FAIL: get_oke_availability_domain prints log lines on stdout; provision-cluster.sh"
    echo "      would pass a multi-line availability domain to 'oci ce node-pool create'"
    return 1
  fi
  ad="${ad_out}"
  echo "ok: availability-domain helper returns one line (${ad})"
  echo "check: GPU limit gpu-a10-count in ${ad} covers ${need} GPU(s)"
  lim_cid="${OCI_TENANCY_OCID:-${OCI_COMPARTMENT_ID}}"
  avail="$(oci limits resource-availability get --service-name compute --limit-name gpu-a10-count \
            --compartment-id "${lim_cid}" --availability-domain "${ad}" --region "${OCI_REGION}" \
            --query 'data.available' --raw-output)" || { echo "FAIL: GPU limit query failed"; return 1; }
  [[ "${avail}" =~ ^[0-9]+$ ]] || { echo "FAIL: GPU limit unreadable: '${avail}'"; return 1; }
  (( avail >= need )) || { echo "FAIL: ${avail} A10 GPU(s) available, ${need} needed"; return 1; }
  echo "ok: GPU limit (${avail} available, ${need} needed)"
  echo "check: OKE GPU node image exists in ${OCI_REGION}"
  # shellcheck source=./oke-optimized-config.sh
  img="$( ( source "${cfg}" >/dev/null 2>&1; echo "${OKE_GPU_IMAGE_ID}" ) )"
  oci compute image get --image-id "${img}" --region "${OCI_REGION}" >/dev/null \
    || { echo "FAIL: OKE GPU image from oke-optimized-config.sh not found in ${OCI_REGION}"; return 1; }
  echo "ok: OKE GPU node image exists in ${OCI_REGION}"
  echo "preflight checks passed"
}

# Returns 0 ready, 1 not ready yet, 2 the port-forward exited right after start.
default_ready_probe() {
  local code i
  if ! is_running "${PF_PID}"; then
    # exec in a subshell: $! is kubectl itself, so stop_running_step finds it.
    ( exec kubectl ${KCTX_ARGS[@]+"${KCTX_ARGS[@]}"} port-forward -n "${NIM_NAMESPACE}" \
        "svc/${NIM_RELEASE}" "${LOCAL_PORT}:8000" < /dev/null >> "${OUT_DIR}/port-forward.log" 2>&1 ) &
    PF_PID=$!
    echo "${PF_PID}" > "${PF_PID_FILE}"
    for i in 1 2 3 4 5 6; do
      sleep 0.5
      if ! is_running "${PF_PID}"; then
        wait "${PF_PID}" 2>/dev/null || true
        echo "$(ts) kubectl port-forward exited at once (local port ${LOCAL_PORT}); last lines:"
        tail -3 "${OUT_DIR}/port-forward.log" 2>/dev/null || true
        PF_PID=""
        return 2
      fi
    done
  fi
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
           "http://127.0.0.1:${LOCAL_PORT}/v1/health/ready" 2>/dev/null || true)"
  echo "$(ts) GET /v1/health/ready on 127.0.0.1:${LOCAL_PORT} -> ${code:-none}"
  [[ "${code}" == "200" ]]
}

isleep() { sleep "$1" & wait $! || true; }   # interruptible by trapped signals

# Step budgets vs the watchdog deadline: a slow but healthy run must not be
# torn down mid-step by the watchdog. Prints the sum; non-zero if too short.
watchdog_budget_check() {
  echo "step budgets: provision ${PROVISION_STEP_TIMEOUT_SEC}s + deploy ${DEPLOY_STEP_TIMEOUT_SEC}s + ready ${READY_TIMEOUT_SEC}s + bench ${BENCH_STEP_TIMEOUT_SEC}s = ${STEP_BUDGET_SUM}s; WATCHDOG_SEC=${WATCHDOG_SEC}s"
  if (( WATCHDOG_SEC >= STEP_BUDGET_SUM )); then
    echo "ok: WATCHDOG_SEC ${WATCHDOG_SEC} >= step-budget sum ${STEP_BUDGET_SUM}"
    return 0
  fi
  if [[ "${ALLOW_SHORT_WATCHDOG}" == "yes" ]]; then
    echo "WARNING: WATCHDOG_SEC ${WATCHDOG_SEC} is smaller than the step-budget sum ${STEP_BUDGET_SUM}; proceeding (ALLOW_SHORT_WATCHDOG=yes)"
    return 0
  fi
  echo "FAIL: WATCHDOG_SEC ${WATCHDOG_SEC} is smaller than the step-budget sum ${STEP_BUDGET_SUM}; the watchdog would stop a slow healthy run. Raise WATCHDOG_SEC to at least ${STEP_BUDGET_SUM}, lower the step timeouts, or set ALLOW_SHORT_WATCHDOG=yes"
  return 1
}

# ------------------------------------------------------------------ main
if [[ "${PREFLIGHT_ONLY}" == "1" ]]; then
  # No watchdog, no provision/deploy/teardown: nothing billable can exist.
  # A signal only stops the running preflight step.
  trap 'stop_running_step preflight-only' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  note "preflight-only start: region=${OCI_REGION} shape=${OKE_GPU_SHAPE} out=${OUT_DIR}"
  phase preflight START 0
  if [[ -z "${OCI_COMPARTMENT_ID:-}" ]]; then
    echo "FAIL: OCI_COMPARTMENT_ID must be set" >> "${OUT_DIR}/preflight.log"
    note "preflight FAILED: OCI_COMPARTMENT_ID must be set"
    phase preflight END 1
    exit 1
  fi
  if ! watchdog_budget_check >> "${OUT_DIR}/preflight.log" 2>&1; then
    note "preflight FAILED: WATCHDOG_SEC ${WATCHDOG_SEC} < step-budget sum ${STEP_BUDGET_SUM} (see preflight.log)"
    phase preflight END 1
    exit 1
  fi
  pf_rc=0
  run_step preflight "${RUNNER_PREFLIGHT:-default_preflight}" || pf_rc=$?
  phase preflight END "${pf_rc}"
  note "preflight-only finished: rc=${pf_rc} (see ${OUT_DIR}/preflight.log)"
  exit "${pf_rc}"
fi

trap on_exit EXIT
# Each handler first ignores the other signals: a pane close delivers INT and
# HUP together, and a second handler's `exit` inside on_exit would end the
# runner before its teardown starts.
trap 'trap "" INT TERM HUP; SIGNAL_NAME=INT; exit 130' INT
trap 'trap "" INT TERM HUP; SIGNAL_NAME=TERM; exit 143' TERM
trap 'trap "" INT TERM HUP; SIGNAL_NAME=HUP; exit 129' HUP

note "run start: region=${OCI_REGION} shape=${OKE_GPU_SHAPE} out=${OUT_DIR}"
phase preflight START 0
if [[ -z "${OCI_COMPARTMENT_ID:-}" || -z "${NGC_KEY_VALUE}" ]]; then
  echo "FAIL: OCI_COMPARTMENT_ID and NGC_API_KEY must be set" >> "${OUT_DIR}/preflight.log"
  note "preflight FAILED: OCI_COMPARTMENT_ID and NGC_API_KEY must be set"
  phase preflight END 1
  exit 1
fi
if ! watchdog_budget_check >> "${OUT_DIR}/preflight.log" 2>&1; then
  note "preflight FAILED: WATCHDOG_SEC ${WATCHDOG_SEC} < step-budget sum ${STEP_BUDGET_SUM} (see preflight.log); nothing created"
  phase preflight END 1
  exit 1
fi
note "step-budget sum ${STEP_BUDGET_SUM}s; watchdog deadline ${WATCHDOG_SEC}s"
pf_rc=0
run_step preflight "${RUNNER_PREFLIGHT:-default_preflight}" || pf_rc=$?
if [[ "${pf_rc}" != "0" ]]; then
  note "preflight FAILED (see preflight.log); nothing created"
  phase preflight END "${pf_rc}"
  exit 1
fi
# Watchdog: own session (python3 os.setsid; macOS has no setsid command),
# double fork so it is re-parented to init at once, started without the
# NGC key. It re-invokes this script with --watchdog-for.
env -u NGC_API_KEY -u NGC_CLI_API_KEY python3 -c '
import os, sys
if os.fork():
    os._exit(0)
os.setsid()
os.execvp(sys.argv[1], sys.argv[1:])
' bash "${SCRIPT_DIR}/run_measured.sh" --watchdog-for "$$" "${OUT_DIR}" \
  < /dev/null >> "${OUT_DIR}/watchdog.log" 2>&1 || true
i=0
while [[ ! -f "${WATCHDOG_ARMED}" ]] && (( i < 20 )); do sleep 0.5; i=$((i + 1)); done
if [[ ! -f "${WATCHDOG_ARMED}" ]]; then
  note "WATCHDOG FAILED TO START (see watchdog.log); nothing created"
  phase preflight END 1
  exit 1
fi
WATCHDOG_PID="$(cat "${OUT_DIR}/watchdog.pid" 2>/dev/null || true)"
note "watchdog armed (pid ${WATCHDOG_PID})"
hold_awake "$$"
phase preflight END 0

# Billable from here: the watchdog now has something to clean up.
now > "${PROVISION_STARTED}"
phase provision START 0
rc=0
STEP_TIMEOUT="${PROVISION_STEP_TIMEOUT_SEC}"
run_step provision "${RUNNER_PROVISION:-${SCRIPT_DIR}/provision-cluster.sh}" || rc=$?
phase provision END "${rc}"
[[ "${rc}" == "124" ]] && note "provision stopped at its ${PROVISION_STEP_TIMEOUT_SEC}s hard timeout"
if [[ -f "${INFO_FILE}" ]]; then
  grep -E '^(CLUSTER_ID|NODE_POOL_ID|GPU_SHAPE|KUBE_CONTEXT)=' "${INFO_FILE}" > "${OUT_DIR}/.oke_ids" 2>/dev/null || true
fi
[[ "${rc}" == "0" ]] || { note "provision FAILED (see provision.log)"; exit 1; }
load_kube_context
kubectl ${KCTX_ARGS[@]+"${KCTX_ARGS[@]}"} version -o json --request-timeout=20s 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["serverVersion"]["gitVersion"])' \
  > "${OUT_DIR}/k8s-version.txt" 2>/dev/null || true

phase deploy START 0
rc=0
STEP_TIMEOUT="${DEPLOY_STEP_TIMEOUT_SEC}"
run_step deploy "${RUNNER_DEPLOY:-${SCRIPT_DIR}/deploy.sh}" || rc=$?
NGC_KEY_VALUE=""   # deploy consumed it; nothing later may inherit it
phase deploy END "${rc}"
[[ "${rc}" == "124" ]] && note "deploy stopped at its ${DEPLOY_STEP_TIMEOUT_SEC}s hard timeout"
[[ "${rc}" == "0" ]] || { note "deploy FAILED (see deploy.log)"; exit 1; }

phase ready START 0
# Local port for the port-forward and bench: NIM_LOCAL_PORT if free, else a
# kernel-chosen free port (8000 is often taken on a workstation).
LOCAL_PORT="${NIM_LOCAL_PORT}"
if [[ -n "${LOCAL_PORT}" ]] && ! port_is_free "${LOCAL_PORT}"; then
  note "NIM_LOCAL_PORT ${LOCAL_PORT} is in use; picking a free port"
  LOCAL_PORT=""
fi
if [[ -z "${LOCAL_PORT}" ]]; then
  LOCAL_PORT="$(free_local_port)" || { note "could not pick a free local port"; phase ready END 1; exit 1; }
fi
note "local port for port-forward and bench: ${LOCAL_PORT}"
deadline=$(( $(now) + READY_TIMEOUT_SEC ))
ready=0
pf_deaths=0
while :; do
  if [[ -n "${RUNNER_READY:-}" ]]; then
    if "${RUNNER_READY}" < /dev/null >> "${OUT_DIR}/ready.log" 2>&1; then ready=1; break; fi
  else
    prc=0
    default_ready_probe >> "${OUT_DIR}/ready.log" 2>&1 || prc=$?
    [[ "${prc}" == "0" ]] && { ready=1; break; }
    if [[ "${prc}" == "2" ]]; then
      pf_deaths=$((pf_deaths + 1))
      if (( pf_deaths >= 3 )); then
        note "ready FAILED: kubectl port-forward to svc/${NIM_RELEASE} exited at once ${pf_deaths} times in a row (see port-forward.log)"
        phase ready END 1
        exit 1
      fi
    else
      pf_deaths=0
    fi
  fi
  (( $(now) >= deadline )) && break
  isleep "${POLL_SEC}"
done
if [[ "${ready}" != "1" ]]; then
  note "ready TIMEOUT after ${READY_TIMEOUT_SEC}s"
  phase ready END 1
  exit 1
fi
phase ready END 0

phase bench START 0
rc=0
STEP_TIMEOUT="${BENCH_STEP_TIMEOUT_SEC}"
if [[ -n "${RUNNER_BENCH:-}" ]]; then
  run_step bench "${RUNNER_BENCH}" --url "http://127.0.0.1:${LOCAL_PORT}" --out "${OUT_DIR}/bench.json" || rc=$?
else
  run_step bench python3 "${SCRIPT_DIR}/bench.py" --url "http://127.0.0.1:${LOCAL_PORT}" \
    --out "${OUT_DIR}/bench.json" || rc=$?
fi
if [[ "${rc}" == "0" ]] && ! python3 -m json.tool "${OUT_DIR}/bench.json" >/dev/null 2>&1; then
  note "bench.json missing or not JSON"
  rc=1
fi
phase bench END "${rc}"
[[ "${rc}" == "124" ]] && note "bench stopped at its ${BENCH_STEP_TIMEOUT_SEC}s hard timeout"
[[ "${rc}" == "0" ]] || { note "bench FAILED (see bench.log)"; exit 1; }

RUN_OK=1
note "bench succeeded; tearing down"
exit 0
