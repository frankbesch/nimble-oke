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
        OCI_COMPARTMENT_ID=ocid1.compartment.oc1..sim OCI_TENANCY_ID=ocid1.tenancy.oc1..sim \
        CONFIRM_COST=yes FORCE=yes \
        NODE_READY_TIMEOUT=5 GPU_ALLOCATABLE_TIMEOUT=3 ADDON_TIMEOUT=5 POLL_INTERVAL=1 \
        "$@" "$BASH_BIN" "$CASE/scripts/$script" > "$CASE/$out" 2>&1
    RC=$?
}
provision() { run provision-cluster.sh "$@"; }
# iam OUTFILE STDIN-TEXT [script args...]: run setup-autoscaler-iam.sh with stubs.
iam() {
    local out="$1" input="$2"
    shift 2
    printf '%s\n' "$input" | env -i PATH="$STUBS:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$CASE/home" TMPDIR="$CASE/tmp" \
        SIM_STATE="$CASE/state" SIM_LOG="$CASE/argv.log" ${SIM_IAM:+SIM_IAM=$SIM_IAM} \
        OCI_COMPARTMENT_ID=ocid1.compartment.oc1..sim OCI_TENANCY_ID=ocid1.tenancy.oc1..sim \
        "$BASH_BIN" "$CASE/scripts/setup-autoscaler-iam.sh" "$@" > "$CASE/$out" 2>&1
    RC=$?
}
# Decoded user_data of the GPU pool create (from the stub's saved --node-metadata).
gpu_user_data() { jq -r '.user_data // empty | @base64d' "$CASE/state/np.metadata"; }
# Lines of $2 (in order) appear in the decoded GPU user_data in Oracle's order.
cloud_init_in_order() {
    local ud a b c
    ud=$(gpu_user_data) || return 1
    a=$(printf '%s\n' "$ud" | grep -n 'opc/v2/instance/metadata/oke_init_script | base64 --decode >/var/run/oke-init.sh' | cut -d: -f1)
    b=$(printf '%s\n' "$ud" | grep -n '^bash /usr/libexec/oci-growfs -y$' | cut -d: -f1)
    c=$(printf '%s\n' "$ud" | grep -n '^bash /var/run/oke-init.sh$' | cut -d: -f1)
    lt "$a" "$b" && lt "$b" "$c"
}
any_create() { grep -Eq '^oci [a-z-]+ [a-z-]+ create( |$)' "$CASE/argv.log"; }
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
         CLUSTER_ID NODE_POOL_ID SYSTEM_NODE_POOL_ID KUBE_CONTEXT; do
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
echo "  -- T1 fixed mode: system pool first, cloud-init growfs, no node mutation"
sp=$(line_of '^oci ce node-pool create .*--name system-node-pool'); gp=$(line_of '^oci ce node-pool create .*--name gpu-node-pool')
check "T1 system pool created before GPU pool (lines $sp < $gp)" lt "$sp" "$gp"
check "T1 system pool: E4.Flex 2 OCPU/16 GB, size 1, newest non-GPU 1.34.1 image, no GPU label" \
    bash -c 'l=$(grep "^oci ce node-pool create .*--name system-node-pool" "$1"); case "$l" in *"--node-shape VM.Standard.E4.Flex "*"\"ocpus\": 2, \"memoryInGBs\": 16"*"--size 1 "*ocid1.image.oc1.phx.sysnew*) ;; *) exit 1 ;; esac; case "$l" in *initial-node-labels*|*bootVolumeSizeInGBs*) exit 1 ;; esac' _ "$CASE/argv.log"
check "T1 GPU pool create carries --node-metadata user_data" grep -q '^oci ce node-pool create .*--name gpu-node-pool .*--node-metadata {"user_data":' "$CASE/argv.log"
check "T1 GPU pool size 1 in fixed mode" grep -qx 1 "$CASE/state/np.size"
check "T1 decoded user_data runs oci-growfs" bash -c 'jq -r ".user_data | @base64d" "$1" | grep -q oci-growfs' _ "$CASE/state/np.metadata"
check "T1 user_data in Oracle's order: fetch init script, oci-growfs, run init script" cloud_init_in_order
check "T1 no nsenter / helper pod created" bash -c '! grep -Eq "nsenter| run nimble-|systemctl" "$1"' _ "$CASE/argv.log"
check "T1 capacity check passed (verification only)" grep -q 'Node gpu-node-1 ephemeral-storage 476Gi (476Gi) >= 150Gi' "$CASE/prov.out"
check "T1 system node Ready before DNS gate" \
    lt "$(grep -n 'System pool node(s) Ready' "$CASE/prov.out" | cut -d: -f1)" "$(grep -n 'DNS check passed' "$CASE/prov.out" | cut -d: -f1)"
check "T1 cluster-info.txt AUTOSCALE=0 and GPU_NODE_SELECTOR" \
    bash -c 'grep -qx AUTOSCALE=0 "$1" && grep -qx GPU_NODE_SELECTOR=nvidia.com/gpu.present=true "$1"' _ "$INFO"
check "T1 no add-on installed in fixed mode" bash -c '! grep -q "install-addon" "$1"' _ "$CASE/argv.log"
check "device plugin applied (no GPU before)" grep -q '^kubectl --context context-csim --request-timeout=30s apply -f .*nvidia-device-plugin.yml' "$CASE/argv.log"
check "allocatable-GPU wait passed" grep -q 'GPU check passed: node allocatable nvidia.com/gpu=1' "$CASE/prov.out"
check "DNS gate passed (Ready kube-dns pod)" grep -q 'DNS check passed: 1 Ready kube-dns pod' "$CASE/prov.out"
check "DNS gate runs after the GPU check" \
    lt "$(grep -n 'GPU check passed' "$CASE/prov.out" | cut -d: -f1)" "$(grep -n 'DNS check passed' "$CASE/prov.out" | cut -d: -f1)"
check "deadline-loop kubectl calls carry --request-timeout=30s" \
    grep -q '^kubectl --context context-csim --request-timeout=30s get nodes -l ' "$CASE/argv.log"
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
echo "  -- T5 teardown with two pools"
gd=$(line_of 'oci ce node-pool delete --node-pool-id ocid1.nodepool.oc1.phx.sim '); sd=$(line_of 'oci ce node-pool delete --node-pool-id ocid1.nodepool.oc1.phx.system ')
check "T5 GPU pool deleted before system pool (lines $gd < $sd)" lt "$gd" "$sd"
check "T5 system pool deleted before cluster (lines $sd < $cl)" lt "$sd" "$cl"
check "T5 both pools confirmed DELETED" test "$(grep -c 'node-pool confirmed DELETED' "$CASE/td.out")" -eq 2
check "T5 pools listed by cluster id" grep -q '^oci ce node-pool list --compartment-id ocid1.compartment.oc1..sim --cluster-id ocid1.cluster.oc1.phx.sim --all' "$CASE/argv.log"
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
check "trap deleted the system pool before the cluster" \
    lt "$(line_of 'oci ce node-pool delete --node-pool-id ocid1.nodepool.oc1.phx.system')" "$(line_of 'oci ce cluster delete')"
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

echo "== L7c / T1 cloud-init growfs had no effect -> capacity check fails with the observed value"
new_case l7c
provision prov.out SIM_GROWFS_NOEFFECT=1
check "provision rc non-zero (rc=$RC)" test "$RC" -ne 0
check "T1 capacity check fails with observed capacity" grep -q 'EPHEMERAL STORAGE CHECK FAILED: node gpu-node-1 reports ephemeral-storage 36Gi' "$CASE/prov.out"
check "T1 node not mutated after the failure" bash -c '! grep -Eq "nsenter| run nimble-" "$1"' _ "$CASE/argv.log"

echo "== L7d no non-GPU x86 OKE image for the version -> fail loudly before the system pool"
new_case l7d
provision prov.out SIM_NO_SYSTEM_IMAGE=1
check "provision rc non-zero (rc=$RC)" test "$RC" -ne 0
check "says no system image found" grep -q 'No Oracle Linux x86_64 non-GPU OKE image found for Kubernetes 1.34.1' "$CASE/prov.out"
check "no node-pool create attempted" bash -c '! grep -q "^oci ce node-pool create" "$1"' _ "$CASE/argv.log"
check "trap deleted the cluster" grep -q '^oci ce cluster delete' "$CASE/argv.log"

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

echo "== L9 cluster DNS never Ready -> provision fails loudly with evidence"
new_case l9
t0=$(date +%s)
provision prov.out SIM_DNS=pending DNS_READY_TIMEOUT=3
t1=$(date +%s)
check "provision rc non-zero (rc=$RC)" test "$RC" -ne 0
check "fails with DNS CHECK FAILED" grep -q 'DNS CHECK FAILED: no Ready kube-dns (CoreDNS) pod after 3s' "$CASE/prov.out"
check "evidence: kube-system pods -o wide (Pending)" grep -q 'coredns-sim   0/1     Pending' "$CASE/prov.out"
check "evidence: describe of the DNS pods (taint vs toleration)" grep -q 'untolerated taint {nvidia.com/gpu: present}' "$CASE/prov.out"
check "evidence: node taints" grep -q 'key:nvidia.com/gpu' "$CASE/prov.out"
check "within the shortened timeout ($((t1 - t0))s < 30s)" test $((t1 - t0)) -lt 30
check "no completion message" bash -c '! grep -q "provisioning complete" "$1"' _ "$CASE/prov.out"

echo "== L10 teardown in a shell whose default region differs: targets the recorded region"
new_case l10
provision prov.out OCI_REGION=us-ashburn-1 SIM_RESOURCE_REGION=us-ashburn-1
check "provision rc 0 (rc=$RC)" test "$RC" -eq 0
check "REGION=us-ashburn-1 recorded" grep -q '^REGION=us-ashburn-1$' "$INFO"
: > "$CASE/argv.log"; : > "$CASE/argv.log.env"
# New shell: OCI_REGION unset (so _lib.sh defaults to us-phoenix-1), ambient OCI_CLI_REGION also other.
teardown td.out SIM_RESOURCE_REGION=us-ashburn-1 OCI_CLI_REGION=eu-frankfurt-1
check "teardown rc 0 (rc=$RC)" test "$RC" -eq 0
[[ $RC -eq 0 ]] || show_tail td.out
check "node-pool delete ran with OCI_CLI_REGION=us-ashburn-1" \
    grep -q '^OCI_CLI_REGION=us-ashburn-1 eff=us-ashburn-1 oci ce node-pool delete' "$CASE/argv.log.env"
check "cluster delete ran with OCI_CLI_REGION=us-ashburn-1" \
    grep -q '^OCI_CLI_REGION=us-ashburn-1 eff=us-ashburn-1 oci ce cluster delete' "$CASE/argv.log.env"
check "no oci call targeted another region" bash -c '! grep -v " eff=us-ashburn-1 " "$1" | grep -q .' _ "$CASE/argv.log.env"
check "resources really deleted (no 404 shortcut)" bash -c 'grep -qx DELETED "$1/cluster" && grep -qx DELETED "$1/np" && ! grep -q "NOTFOUND" "$2"' _ "$CASE/state" "$CASE/td.out"

echo "== L10b OCI_REGION conflicts with the recorded REGION -> refuse, never report clean"
new_case l10b
provision prov.out OCI_REGION=us-ashburn-1 SIM_RESOURCE_REGION=us-ashburn-1
: > "$CASE/argv.log"; : > "$CASE/argv.log.env"
teardown td.out SIM_RESOURCE_REGION=us-ashburn-1 OCI_REGION=us-phoenix-1
check "teardown rc non-zero (rc=$RC)" test "$RC" -ne 0
check "says REGION MISMATCH" grep -q 'REGION MISMATCH: OCI_REGION=us-phoenix-1 but .* records REGION=us-ashburn-1' "$CASE/td.out"
check "no oci call made" test ! -s "$CASE/argv.log.env"
check "no success wording" bash -c '! grep -Eq "Teardown complete|confirmed deleted|already deleted" "$1"' _ "$CASE/td.out"
check "cluster-info.txt kept" test -f "$INFO"
check "simulated cluster still ACTIVE" grep -qx ACTIVE "$CASE/state/cluster"

echo "== L11 PV left by a failed deploy (PVC already gone) never deletes -> exit 2 with its volume OCID"
new_case l11
provision prov.out
printf 'pvc-orphan\tocid1.volume.oc1.phx.orphan\t-\n' > "$CASE/state/pvs"
: > "$CASE/argv.log"
teardown td.out SIM_PV_STUCK=1 PV_DELETE_TIMEOUT=2 PV_POLL_SEC=1
check "teardown rc 2 (rc=$RC)" test "$RC" -eq 2
check "PV with no PVC was collected (get pv before node-pool delete)" \
    lt "$(line_of 'kubectl .*get pv -o jsonpath=')" "$(line_of 'oci ce node-pool delete')"
check "possible orphan reports the volumeHandle" grep -q 'POSSIBLE ORPHAN: PersistentVolume pvc-orphan .*block volume ocid1.volume.oc1.phx.orphan' "$CASE/td.out"
check "final orphan list names the volume" grep -q 'POSSIBLE ORPHAN block volume: ocid1.volume.oc1.phx.orphan' "$CASE/td.out"
check "GPU node pool and cluster still deleted" bash -c 'grep -qx DELETED "$1/np" && grep -qx DELETED "$1/cluster"' _ "$CASE/state"
check "cluster-info.txt kept" test -f "$INFO"

echo "== L11b bound and released oci-bv PVs deleted after the PVC delete -> clean"
new_case l11b
provision prov.out
printf 'pvc-bound\tocid1.volume.oc1.phx.bound\tnvidia-nim-cache\npvc-released\tocid1.volume.oc1.phx.rel\t-\n' > "$CASE/state/pvs"
: > "$CASE/argv.log"
teardown td.out PV_DELETE_TIMEOUT=5 PV_POLL_SEC=1
check "teardown rc 0 (rc=$RC)" test "$RC" -eq 0
[[ $RC -eq 0 ]] || show_tail td.out
check "waited for both PVs" grep -q 'PersistentVolume(s) deleted: pvc-bound pvc-released' "$CASE/td.out"
check "PVC delete before node-pool delete" lt "$(line_of 'delete pvc ')" "$(line_of 'oci ce node-pool delete')"
check "cluster-info.txt removed" test ! -f "$INFO"

echo "== L12 no cluster recorded or found, but a node pool with the project's name exists -> not deleted"
new_case l12
printf 'OCI_COMPARTMENT_ID=ocid1.compartment.oc1..sim\nREGION=us-phoenix-1\nCLUSTER_NAME=nimble-oke-cluster\nNODE_POOL_NAME=gpu-node-pool\n' > "$INFO"
echo ACTIVE > "$CASE/state/np"   # someone else's pool, no cluster of ours
teardown td.out
check "teardown rc non-zero (rc=$RC)" test "$RC" -ne 0
check "reports the foreign pool, not deleting" grep -q 'NOT deleting it (it may belong to someone else)' "$CASE/td.out"
check "no node-pool delete issued" bash -c '! grep -q "^oci ce node-pool delete" "$1"' _ "$CASE/argv.log"
check "foreign pool still ACTIVE" grep -qx ACTIVE "$CASE/state/np"

echo "== T2 AUTOSCALE=1 provision: GPU pool size 0, add-on installed, no GPU wait"
new_case t2
provision prov.out AUTOSCALE=1 SIM_IAM=present
check "provision rc 0 (rc=$RC)" test "$RC" -eq 0
[[ $RC -eq 0 ]] || show_tail prov.out
check "T2 IAM check ran before any create" lt "$(line_of '^oci iam policy list')" "$(grep -En '^oci [a-z-]+ [a-z-]+ create( |$)' "$CASE/argv.log" | head -1 | cut -d: -f1)"
sp=$(line_of '^oci ce node-pool create .*--name system-node-pool'); gp=$(line_of '^oci ce node-pool create .*--name gpu-node-pool')
check "T2 system pool before GPU pool (lines $sp < $gp)" lt "$sp" "$gp"
check "T2 GPU pool created with --size 0" grep -q '^oci ce node-pool create .*--name gpu-node-pool .*--size 0 ' "$CASE/argv.log"
check "T2 GPU pool carries the GPU label" grep -q '"key": "nvidia.com/gpu.present", "value": "true"' "$CASE/state/np.labels"
check "T2 GPU pool cloud-init in Oracle's order" cloud_init_in_order
check "T2 ephemeral-storage freeform tag = 400Gi" \
    test "$(jq -r '.["cluster-autoscaler/node-ephemeral-storage"]' "$CASE/state/np.tags")" = 400Gi
check "T2 add-on name ClusterAutoscaler" grep -qx ClusterAutoscaler "$CASE/state/addon.name"
cfgv() { jq -r --arg k "$1" '.configurations[] | select(.key == $k) | .value' "$CASE/state/addon.json"; }
check "T2 add-on nodes=0:1:<gpu pool ocid>" test "$(cfgv nodes)" = "0:1:ocid1.nodepool.oc1.phx.sim"
check "T2 add-on scaleDownUnneededTime=3m" test "$(cfgv scaleDownUnneededTime)" = 3m
check "T2 add-on scaleDownDelayAfterAdd=3m" test "$(cfgv scaleDownDelayAfterAdd)" = 3m
check "T2 add-on authType=instance, maxNodeProvisionTime=25m" \
    bash -c 'test "$1" = instance && test "$2" = 25m' _ "$(cfgv authType)" "$(cfgv maxNodeProvisionTime)"
check "T2 autoscaler pod Running on the system node" grep -q 'pod cluster-autoscaler-sim-1 Running on system node system-node-1' "$CASE/prov.out"
check "T2 no wait for a GPU node or allocatable GPU" \
    bash -c '! grep -Eq "GPU nodes Ready|GPU check passed|Node .* ephemeral-storage" "$1" && ! grep -q "allocatable" "$2"' _ "$CASE/prov.out" "$CASE/argv.log"
check "T2 device plugin DaemonSet ensured (applied: none present)" grep -q 'apply -f .*nvidia-device-plugin.yml' "$CASE/argv.log"
check "T2 DNS gate passed" grep -q 'DNS check passed' "$CASE/prov.out"
for kv in AUTOSCALE=1 GPU_NODE_SELECTOR=nvidia.com/gpu.present=true MAX_GPU_NODES=1 \
          NODE_POOL_ID=ocid1.nodepool.oc1.phx.sim SYSTEM_NODE_POOL_ID=ocid1.nodepool.oc1.phx.system; do
    check "T2 cluster-info.txt has $kv" grep -qx "$kv" "$INFO"
done
: > "$CASE/argv.log"
teardown td.out
check "T2 teardown rc 0 (rc=$RC)" test "$RC" -eq 0
check "T2 teardown deleted both pools and the cluster" \
    bash -c 'grep -qx DELETED "$1/np" && grep -qx DELETED "$1/np.system" && grep -qx DELETED "$1/cluster"' _ "$CASE/state"

echo "== T3 AUTOSCALE=1 with the IAM check failing -> nothing created"
new_case t3
provision prov.out AUTOSCALE=1
check "T3 provision rc non-zero (rc=$RC)" test "$RC" -ne 0
check "T3 says PREFLIGHT FAILED and to run --apply" grep -q 'PREFLIGHT FAILED: Cluster Autoscaler IAM .* --apply' "$CASE/prov.out"
check "T3 zero create calls in the argv log" bash -c '! grep -Eq "^oci [a-z-]+ [a-z-]+ create( |$)" "$1"' _ "$CASE/argv.log"
check "T3 no cluster-info.txt written" test ! -f "$INFO"

echo "== T4 add-on never ACTIVE -> provision fails loudly; teardown removes both pools and the cluster"
new_case t4
t0=$(date +%s)
provision prov.out AUTOSCALE=1 SIM_IAM=present SIM_ADDON=never ADDON_TIMEOUT=3
t1=$(date +%s)
check "T4 provision rc non-zero (rc=$RC)" test "$RC" -ne 0
check "T4 fails with AUTOSCALER CHECK FAILED and the state" grep -q "AUTOSCALER CHECK FAILED: add-on state 'NEEDS_ATTENTION'" "$CASE/prov.out"
check "T4 evidence: get-addon output" grep -q '"lifecycle-state":"NEEDS_ATTENTION"' "$CASE/prov.out"
check "T4 evidence: autoscaler pod Pending" grep -q 'cluster-autoscaler-sim-1   0/1     Pending' "$CASE/prov.out"
check "T4 within the shortened timeout ($((t1 - t0))s < 30s)" test $((t1 - t0)) -lt 30
check "T4 no completion message" bash -c '! grep -q "provisioning complete" "$1"' _ "$CASE/prov.out"
: > "$CASE/argv.log"
teardown td.out
check "T4 teardown rc 0 (rc=$RC)" test "$RC" -eq 0
[[ $RC -eq 0 ]] || show_tail td.out
check "T4 GPU pool deleted first, then system pool, then cluster" \
    bash -c 'lt() { [[ -n "$1" && -n "$2" && "$1" -lt "$2" ]]; }; g=$(grep -n "node-pool delete --node-pool-id ocid1.nodepool.oc1.phx.sim " "$1" | head -1 | cut -d: -f1); s=$(grep -n "node-pool delete --node-pool-id ocid1.nodepool.oc1.phx.system " "$1" | head -1 | cut -d: -f1); c=$(grep -n "^oci ce cluster delete" "$1" | head -1 | cut -d: -f1); lt "$g" "$s" && lt "$s" "$c"' _ "$CASE/argv.log"
check "T4 both pools and the cluster DELETED" \
    bash -c 'grep -qx DELETED "$1/np" && grep -qx DELETED "$1/np.system" && grep -qx DELETED "$1/cluster"' _ "$CASE/state"

echo "== T5b one of two pool deletes fails -> rc 1, file kept, cluster kept"
new_case t5b
provision prov.out
: > "$CASE/argv.log"
teardown td.out SIM_NP_DELETE_FAIL=system
check "T5 teardown rc 1 (rc=$RC)" test "$RC" -eq 1
check "T5 cluster-info.txt kept" test -f "$INFO"
check "T5 GPU pool still deleted" grep -qx DELETED "$CASE/state/np"
check "T5 cluster delete not attempted" bash -c '! grep -q "^oci ce cluster delete" "$1"' _ "$CASE/argv.log"
check "T5 loud incomplete message" grep -q 'TEARDOWN INCOMPLETE' "$CASE/td.out"

echo "== T6 setup-autoscaler-iam.sh"
new_case t6
iam print.out "" --print
check "T6 --print rc 0 (rc=$RC)" test "$RC" -eq 0
check "T6 --print shows six statements for the compartment name" \
    test "$(grep -c '^Allow dynamic-group nimble-oke-autoscaler to .* in compartment sim-compartment$' "$CASE/print.out")" -eq 6
check "T6 --print shows the rule with the compartment OCID" grep -qx "ALL {instance.compartment.id = 'ocid1.compartment.oc1..sim'}" "$CASE/print.out"
for v in "manage cluster-node-pools" "manage instance-family" "use subnets" "read virtual-network-family" "use vnics" "inspect compartments"; do
    check "T6 statement: $v" grep -q "to $v in compartment sim-compartment" "$CASE/print.out"
done
iam check1.out "" --check
check "T6 --check rc 3 when missing (rc=$RC)" test "$RC" -eq 3
check "T6 --check names what is missing" grep -q "missing: dynamic group 'nimble-oke-autoscaler'" "$CASE/check1.out"
SIM_IAM=present iam check2.out "" --check
check "T6 --check rc 0 when the objects match (rc=$RC)" test "$RC" -eq 0
: > "$CASE/argv.log"
iam apply1.out "wrong-name" --apply
check "T6 --apply with a wrong typed name: rc non-zero (rc=$RC)" test "$RC" -ne 0
check "T6 --apply with a wrong typed name: no create call" bash -c '! grep -q " create" "$1"' _ "$CASE/argv.log"
iam apply2.out "" --apply
check "T6 --apply with no input: no create call" bash -c '! grep -q " create" "$1"' _ "$CASE/argv.log"
iam apply3.out "sim-compartment" --apply
check "T6 --apply with the typed name creates both, then --check passes (rc=$RC)" \
    bash -c 'test "$1" -eq 0 && grep -q "^oci iam dynamic-group create" "$2" && grep -q "^oci iam policy create" "$2"' _ "$RC" "$CASE/argv.log"
check "T6 policy attached to the compartment" grep -q '^oci iam policy create --compartment-id ocid1.compartment.oc1..sim ' "$CASE/argv.log"
iam del.out "sim-compartment" --delete
check "T6 --delete removes exactly the two objects (rc=$RC)" \
    bash -c 'test "$1" -eq 0 && grep -q "^oci iam policy delete --policy-id ocid1.policy.oc1..sim" "$2" && grep -q "^oci iam dynamic-group delete --dynamic-group-id ocid1.dynamicgroup.oc1..sim" "$2"' _ "$RC" "$CASE/argv.log"

# L8 deploy: added after deploy.sh settles

echo
if [[ $FAILS -eq 0 ]]; then
    echo "RESULT: all passed"
    exit 0
fi
echo "RESULT: $FAILS failed"
exit 1
