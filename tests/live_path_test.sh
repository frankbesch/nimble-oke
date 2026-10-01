#!/usr/bin/env bash
# Live-path test: runs the REAL provision-cluster.sh and teardown-cluster.sh
# against stateful offline stubs (tests/stubs-stateful/{oci,kubectl,helm}).
# Each case runs in a scratch copy of the repo with HOME, KUBECONFIG and
# TMPDIR pointed at scratch dirs. No network, no cloud, no cluster.
# Needs bash, jq, bc, awk. Runs on bash 3.2 (macOS) and bash 5 (CI).
set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TESTS_DIR/.." && pwd)"
STUBS="$TESTS_DIR/stubs-stateful"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/live-path.XXXXXX")"
if [[ -n "${KEEP_WORK:-}" ]]; then echo "work dir kept: $WORK"; else trap 'rm -rf "$WORK"' EXIT; fi

FAILS=0
ok()  { echo "  PASS: $*"; }
bad() { echo "  FAIL: $*"; FAILS=$((FAILS + 1)); }
check() { local msg="$1"; shift; if "$@"; then ok "$msg"; else bad "$msg"; fi; }

# The scripts run under the same bash as this test.
BASH_BIN="${BASH:-bash}"
OTHER_CLUSTER=ocid1.cluster.oc1.phx.OTHER

new_case() {
    CASE="$WORK/$1"
    mkdir -p "$CASE/home" "$CASE/tmp" "$CASE/state"
    cp -R "$REPO/scripts" "$CASE/"
    [[ -d "$REPO/helm" ]] && cp -R "$REPO/helm" "$CASE/"
    rm -f "$CASE/scripts/cluster-info.txt"
    KCFG="$CASE/home/kubeconfig-test"   # deliberately not ~/.kube/config
    printf 'other-ctx\tother-cluster\tother-user\t%s\n' "$OTHER_CLUSTER" > "$KCFG"
    echo other-ctx > "$KCFG.current"
    : > "$CASE/argv.log"
    INFO="$CASE/scripts/cluster-info.txt"
}

# run SCRIPT OUTFILE [VAR=value ...]
run() {
    local script="$1" out="$2"
    shift 2
    env -i PATH="$STUBS:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$CASE/home" TMPDIR="$CASE/tmp" \
        KUBECONFIG="$KCFG" SIM_STATE="$CASE/state" SIM_LOG="$CASE/argv.log" \
        OCI_COMPARTMENT_ID=ocid1.compartment.oc1..sim CONFIRM_COST=yes FORCE=yes \
        NODE_READY_TIMEOUT=5 GROWFS_TIMEOUT=5 GPU_ALLOCATABLE_TIMEOUT=3 POLL_INTERVAL=1 \
        "$@" "$BASH_BIN" "$CASE/scripts/$script" > "$CASE/$out" 2>&1
    RC=$?
}
provision() { run provision-cluster.sh "$@"; }
teardown()  { run teardown-cluster.sh "$@"; }

line_of()      { grep -n -- "$1" "$CASE/argv.log" | head -1 | cut -d: -f1; }
last_line_of() { grep -n -- "$1" "$CASE/argv.log" | tail -1 | cut -d: -f1; }
lt() { [[ -n "$1" && -n "$2" && "$1" -lt "$2" ]]; }
has_key() { grep -q "^$1=." "$INFO"; }
show_tail() { echo "  --- last lines of $1:"; tail -15 "$CASE/$1" | sed 's/^/      /'; }

echo "== L1 provision success (bash $BASH_VERSION)"
new_case l1
provision prov.out
check "provision rc 0 (rc=$RC)" test "$RC" -eq 0
[[ $RC -eq 0 ]] || show_tail prov.out
for k in OCI_COMPARTMENT_ID REGION VCN_ID API_SECLIST_ID WORKER_SECLIST_ID API_SUBNET_ID SUBNET_ID \
         CLUSTER_ID NODE_POOL_ID KUBE_CONTEXT; do
    check "cluster-info.txt has $k" has_key "$k"
done
check "VCN_CREATED=yes recorded" grep -q '^VCN_CREATED=yes$' "$INFO"
check "VCN create uses --cidr-blocks" grep -q '^oci network vcn create .*--cidr-blocks \["10.0.0.0/16"\]' "$CASE/argv.log"
sl1=$(line_of 'oci network security-list create'); sn1=$(line_of 'oci network subnet create')
check "security lists created before subnets (lines $sl1 < $sn1)" lt "$sl1" "$sn1"
check "API subnet attached to API security list" \
    grep -q 'oci network subnet create .*nimble-oke-subnet-api .*--security-list-ids \["ocid1.securitylist.oc1.phx.api"\]' "$CASE/argv.log"
check "worker subnet attached to worker security list" \
    grep -q 'oci network subnet create .*nimble-oke-subnet-workers .*--security-list-ids \["ocid1.securitylist.oc1.phx.workers"\]' "$CASE/argv.log"
check "API list: worker->API 12250 rule" grep -q '"source":"10.0.1.0/24".*"min":12250' "$CASE/state/sl.api"
check "API list: external 6443 from API_ALLOWED_CIDR default" grep -q '"source":"0.0.0.0/0","sourceType":"CIDR_BLOCK","protocol":"6"' "$CASE/state/sl.api"
check "worker list: node-to-node all protocols" grep -q '"source":"10.0.1.0/24","sourceType":"CIDR_BLOCK","protocol":"all"' "$CASE/state/sl.workers"
check "worker list: control plane TCP" grep -q '"source":"10.0.0.0/28","sourceType":"CIDR_BLOCK","protocol":"6"' "$CASE/state/sl.workers"
check "no SSH 22 rule in either list" bash -c '! grep -q "\"min\":22[,}]" "$1"/sl.api "$1"/sl.workers' _ "$CASE/state"
check "egress allow-all on both lists" bash -c 'grep -q "\"destination\":\"0.0.0.0/0\"" "$1"/sl.api.egress && grep -q "\"destination\":\"0.0.0.0/0\"" "$1"/sl.workers.egress' _ "$CASE/state"
check "route-table update ran (not swallowed)" grep -q '^oci network route-table update ' "$CASE/argv.log"
check "node-pool create carries GPU label" \
    grep -q '^oci ce node-pool create .*--initial-node-labels \[{"key": "nvidia.com/gpu.present", "value": "true"}\]' "$CASE/argv.log"
check "kubeconfig written to \$KUBECONFIG" grep -q -- "create-kubeconfig .*--file $KCFG " "$CASE/argv.log"
check "KUBE_CONTEXT=context-csim" grep -q '^KUBE_CONTEXT=context-csim$' "$INFO"
check "post-kubeconfig kubectl node calls pinned with --context" \
    bash -c '! grep "^kubectl " "$1" | grep -v "^kubectl config " | grep -vq -- "--context context-csim"' _ "$CASE/argv.log"
check "growfs step ran" grep -q '^kubectl --context context-csim -n kube-system run nimble-growfs-.*oci-growfs' "$CASE/argv.log"
check "kubelet restart ran after growfs" grep -q 'run nimble-restart-kubelet-.*systemctl' "$CASE/argv.log"
check "ephemeral storage reported grown" grep -q 'ephemeral-storage now 476Gi' "$CASE/prov.out"
check "device plugin applied (no GPU before)" grep -q '^kubectl --context context-csim apply -f .*nvidia-device-plugin.yml' "$CASE/argv.log"
check "allocatable-GPU wait passed" grep -q 'GPU check passed: node allocatable nvidia.com/gpu=1' "$CASE/prov.out"
check "other kube context untouched" grep -q "^other-ctx	other-cluster	other-user	$OTHER_CLUSTER" "$KCFG"

echo "== L2 teardown after L1"
: > "$CASE/argv.log"
teardown td.out
check "teardown rc 0 (rc=$RC)" test "$RC" -eq 0
[[ $RC -eq 0 ]] || show_tail td.out
np=$(line_of 'oci ce node-pool delete'); cl=$(line_of 'oci ce cluster delete')
sn=$(line_of 'oci network subnet delete'); snl=$(last_line_of 'oci network subnet delete')
sl=$(line_of 'oci network security-list delete'); sll=$(last_line_of 'oci network security-list delete')
vc=$(line_of 'oci network vcn delete')
echo "  argv lines: node-pool=$np cluster=$cl subnets=$sn..$snl seclists=$sl..$sll vcn=$vc"
check "order node pool < cluster" lt "$np" "$cl"
check "order cluster < subnets" lt "$cl" "$sn"
check "order subnets < security lists" lt "$snl" "$sl"
check "order security lists < VCN (VCN created by this project)" lt "$sll" "$vc"
check "both security lists deleted" test "$(grep -c '^oci network security-list delete' "$CASE/argv.log")" -eq 2
check "cluster-info.txt removed" test ! -f "$INFO"
check "this cluster's context removed" bash -c '! grep -q "^context-csim" "$1"' _ "$KCFG"
check "second dummy kube context untouched" grep -q "^other-ctx	other-cluster	other-user	$OTHER_CLUSTER" "$KCFG"
check "no simulated resources left" bash -c '! ls "$1"/vcn "$1"/igw "$1"/subnet.* "$1"/sl.* >/dev/null 2>&1' _ "$CASE/state"

echo "== L3 node-pool create fails -> trap, then teardown twice"
new_case l3
provision prov.out SIM_NP_CREATE_FAIL=1
check "provision rc non-zero (rc=$RC)" test "$RC" -ne 0
check "trap deleted the cluster" grep -q '^oci ce cluster delete --cluster-id ocid1.cluster.oc1.phx.sim' "$CASE/argv.log"
check "trap confirmed cleanup" grep -q 'Failure cleanup confirmed' "$CASE/prov.out"
teardown td1.out
check "teardown rc 0 (rc=$RC)" test "$RC" -eq 0
[[ $RC -eq 0 ]] || show_tail td1.out
check "k8s step reported nothing to do" grep -q 'Kubernetes resources: nothing to do' "$CASE/td1.out"
check "no 'possible orphans' warning" bash -c '! grep -q "ORPHANED" "$1"' _ "$CASE/td1.out"
check "cluster-info.txt removed" test ! -f "$INFO"
n0=$(wc -l < "$CASE/argv.log")
teardown td2.out
check "second teardown says nothing to tear down (rc=$RC)" grep -q 'Nothing to tear down' "$CASE/td2.out"
check "second teardown made no cloud calls" test "$(wc -l < "$CASE/argv.log")" -eq "$n0"

echo "== L4 node-pool delete fails"
new_case l4
provision prov.out
check "provision rc 0 (rc=$RC)" test "$RC" -eq 0
teardown td.out SIM_NP_DELETE_FAIL=1
check "teardown rc 1 (rc=$RC)" test "$RC" -eq 1
check "cluster-info.txt kept" test -f "$INFO"
check "cluster delete not attempted" bash -c '! grep -q "^oci ce cluster delete" "$1"' _ "$CASE/argv.log"
check "no success wording" bash -c '! grep -Eq "Teardown complete|confirmed deleted - GPU" "$1"' _ "$CASE/td.out"
check "loud incomplete message" grep -q 'TEARDOWN INCOMPLETE' "$CASE/td.out"

echo "== L5a get after delete returns 404 -> deleted"
new_case l5a
provision prov.out
check "provision rc 0 (rc=$RC)" test "$RC" -eq 0
teardown td.out SIM_GONE_AS_404=1
check "teardown rc 0 (rc=$RC)" test "$RC" -eq 0
[[ $RC -eq 0 ]] || show_tail td.out
check "node pool 404 treated as deleted" grep -q 'node-pool confirmed DELETED (NOTFOUND)' "$CASE/td.out"
check "cluster 404 treated as deleted" grep -q 'cluster confirmed DELETED (NOTFOUND)' "$CASE/td.out"
check "cluster-info.txt removed" test ! -f "$INFO"

echo "== L5b get fails with an auth error -> NOT deleted"
new_case l5b
provision prov.out
teardown td.out SIM_GET_AUTH_FAIL=node-pool
check "teardown rc 1 (rc=$RC)" test "$RC" -eq 1
check "auth error not treated as deleted" grep -q 'Could not confirm node-pool deletion' "$CASE/td.out"
check "cluster-info.txt kept" test -f "$INFO"
check "cluster delete not attempted" bash -c '! grep -q "^oci ce cluster delete" "$1"' _ "$CASE/argv.log"
nf_check() {  # $1 expected (yes/no)  $2 error text
    local got
    got=$(env -i PATH=/usr/bin:/bin HOME="$CASE/home" "$BASH_BIN" -c \
        'source "$1/_lib.sh" >/dev/null 2>&1; set +e; printf "%s" "$2" | oci_is_not_found_error && echo yes || echo no' \
        _ "$CASE/scripts" "$2")
    [[ "$got" == "$1" ]]
}
check "classifier: NotAuthorizedOrNotFound -> not found" nf_check yes '"code": "NotAuthorizedOrNotFound", "status": 404'
check "classifier: NotAuthenticated 401 -> NOT not-found" nf_check no '"code": "NotAuthenticated", "status": 401'
check "classifier: ConfigFileNotFound -> NOT not-found" nf_check no 'ConfigFileNotFound: Could not find config file'
check "classifier: connect timeout -> NOT not-found" nf_check no 'RequestException: ConnectTimeout'

echo "== L6 cluster create work request ends FAILED"
new_case l6
provision prov.out SIM_CL_WR=FAILED
check "provision rc non-zero (rc=$RC)" test "$RC" -ne 0
check "says work request FAILED" grep -q 'cluster create work request ended in state FAILED' "$CASE/prov.out"
check "node-pool create not attempted" bash -c '! grep -q "^oci ce node-pool create" "$1"' _ "$CASE/argv.log"
check "trap deleted the FAILED cluster" grep -q '^oci ce cluster delete --cluster-id ocid1.cluster.oc1.phx.sim' "$CASE/argv.log"

echo "== L7 allocatable GPU never appears"
new_case l7
t0=$(date +%s)
provision prov.out SIM_GPU=never
t1=$(date +%s)
check "provision rc non-zero (rc=$RC)" test "$RC" -ne 0
check "fails loudly with GPU CHECK FAILED" grep -q 'GPU CHECK FAILED: no node reports allocatable nvidia.com/gpu after 3s' "$CASE/prov.out"
check "device plugin was applied first" grep -q 'apply -f .*nvidia-device-plugin.yml' "$CASE/argv.log"
check "within the shortened timeout ($((t1 - t0))s < 30s)" test $((t1 - t0)) -lt 30
check "no completion message" bash -c '! grep -q "provisioning complete" "$1"' _ "$CASE/prov.out"

echo "== L7b device plugin already present -> upstream manifest not applied"
new_case l7b
provision prov.out SIM_GPU=preinstalled
check "provision rc 0 (rc=$RC)" test "$RC" -eq 0
check "upstream manifest not applied" bash -c '! grep -q "apply -f" "$1"' _ "$CASE/argv.log"

echo "== L7c growfs has no effect -> provision fails with the observed value"
new_case l7c
provision prov.out SIM_GROWFS_NOEFFECT=1
check "provision rc non-zero (rc=$RC)" test "$RC" -ne 0
check "reports observed capacity" grep -q 'GROWFS FAILED: node gpu-node-1 ephemeral-storage capacity is 36Gi' "$CASE/prov.out"

echo "== L1c pre-existing VCN named nimble-oke-vcn (with gateway) is reused, never deleted"
new_case l1c
echo AVAILABLE > "$CASE/state/vcn"; touch "$CASE/state/igw"
echo '[{"destination":"0.0.0.0/0","network-entity-id":"ocid1.internetgateway.oc1.phx.sim"}]' > "$CASE/state/rt-rules"
provision prov.out
check "provision rc 0 (rc=$RC)" test "$RC" -eq 0
check "VCN_CREATED=no recorded" grep -q '^VCN_CREATED=no$' "$INFO"
check "no VCN or gateway create" bash -c '! grep -Eq "^oci network (vcn|internet-gateway) create" "$1"' _ "$CASE/argv.log"
check "existing route rule kept (no route update)" bash -c '! grep -q "^oci network route-table update" "$1"' _ "$CASE/argv.log"
: > "$CASE/argv.log"
teardown td.out
check "teardown rc 0 (rc=$RC)" test "$RC" -eq 0
check "subnets and security lists deleted" bash -c 'grep -q "^oci network subnet delete" "$1" && grep -q "^oci network security-list delete" "$1"' _ "$CASE/argv.log"
check "VCN, gateway, route rules untouched" bash -c '! grep -Eq "^oci network (vcn delete|internet-gateway delete|route-table update)" "$1"' _ "$CASE/argv.log"
check "VCN still exists in the simulation" test -f "$CASE/state/vcn"

# L8 deploy: added after deploy.sh settles

echo
if [[ $FAILS -eq 0 ]]; then
    echo "RESULT: all passed"
    exit 0
fi
echo "RESULT: $FAILS failed"
exit 1
