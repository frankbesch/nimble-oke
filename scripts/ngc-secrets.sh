#!/usr/bin/env bash
# Agent-blind NGC key helper: creates and deletes the two Kubernetes Secrets
# that hold the NGC key, without the key ever entering this shell's
# variables, the caller's environment, a command line, or a file on disk.
#
# Usage:
#   scripts/ngc-secrets.sh create      [SOURCE] [--release NAME] [--namespace NS]
#   scripts/ngc-secrets.sh create-pull [SOURCE] [--release NAME] [--namespace NS]
#   scripts/ngc-secrets.sh create-api  [SOURCE] [--release NAME] [--namespace NS]
#   scripts/ngc-secrets.sh delete-api            [--release NAME] [--namespace NS]
#   scripts/ngc-secrets.sh delete                [--release NAME] [--namespace NS]
#   scripts/ngc-secrets.sh check       [SOURCE]
#
# SOURCE (first match wins):
#   --key-keychain SERVICE  macOS Keychain generic password (security -w -s SERVICE)
#   --key-file PATH         first line of PATH (mode 600 or 400)
#   env NGC_KEY_KEYCHAIN    same as --key-keychain (a service name, not a key)
#   env NGC_KEY_FILE        same as --key-file (a path, not a key)
#   env NGC_API_KEY         fallback only: the key is then already in the caller's env
#
# Secrets (names follow the chart's fullname rule, helm/templates/_helpers.tpl):
#   <fullname>-ngc-registry  kubernetes.io/dockerconfigjson, for the kubelet's image pull
#   <fullname>-ngc-api       Opaque, key NGC_API_KEY, read only by the pre-stage Job
#
# How the key moves: the source command writes it to a pipe; awk keeps the
# first line and drops the newline; kubectl reads it from /dev/stdin
# (--from-file=KEY=/dev/stdin). For the pull secret, jq builds the
# dockerconfigjson from the same pipe. No step writes the key to stdout,
# stderr, argv or disk. `check` confirms the source exists without reading
# the key (Keychain: `security find-generic-password -s` without -w).
#
# Secrets made here carry app.kubernetes.io/instance=<release>, so
# scripts/cleanup-nim.sh removes them with the chart's own resources.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

CHART_NAME="nvidia-nim"   # helm/Chart.yaml name
REGISTRY="nvcr.io"
REGISTRY_USER='$oauthtoken'

usage() {
    sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

ACTION="${1:-}"
[[ -n "${ACTION}" ]] || { usage >&2; exit 2; }
shift
KEYCHAIN_SERVICE=""
KEY_FILE_PATH=""
RELEASE="nvidia-nim"
NAMESPACE="default"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --key-keychain) KEYCHAIN_SERVICE="${2:-}"; [[ -n "${KEYCHAIN_SERVICE}" ]] || { usage >&2; exit 2; }; shift ;;
        --key-file) KEY_FILE_PATH="${2:-}"; [[ -n "${KEY_FILE_PATH}" ]] || { usage >&2; exit 2; }; shift ;;
        --release) RELEASE="${2:-}"; [[ -n "${RELEASE}" ]] || { usage >&2; exit 2; }; shift ;;
        --namespace|-n) NAMESPACE="${2:-}"; [[ -n "${NAMESPACE}" ]] || { usage >&2; exit 2; }; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
    shift
done

# Same rule as "nvidia-nim.fullname": the release name alone when it already
# contains the chart name, else "<release>-<chart>"; 63 characters at most.
fullname() {
    local f
    if [[ "${RELEASE}" == *"${CHART_NAME}"* ]]; then f="${RELEASE}"; else f="${RELEASE}-${CHART_NAME}"; fi
    f="${f:0:63}"
    printf '%s' "${f%-}"
}
trim63() { local s="${1:0:63}"; printf '%s' "${s%-}"; }
PULL_SECRET="$(trim63 "$(fullname)-ngc-registry")"
API_SECRET="$(trim63 "$(fullname)-ngc-api")"

# Resolve the source once. Only names and paths are held here, never the key.
SOURCE_KIND=""
if [[ -n "${KEYCHAIN_SERVICE}" ]]; then SOURCE_KIND="keychain"
elif [[ -n "${KEY_FILE_PATH}" ]]; then SOURCE_KIND="file"
elif [[ -n "${NGC_KEY_KEYCHAIN:-}" ]]; then SOURCE_KIND="keychain"; KEYCHAIN_SERVICE="${NGC_KEY_KEYCHAIN}"
elif [[ -n "${NGC_KEY_FILE:-}" ]]; then SOURCE_KIND="file"; KEY_FILE_PATH="${NGC_KEY_FILE}"
elif [[ -n "${NGC_API_KEY:-}" ]]; then SOURCE_KIND="env"
fi

check_source() {
    case "${SOURCE_KIND}" in
        keychain)
            command -v security >/dev/null 2>&1 \
                || { log_error "--key-keychain needs the macOS 'security' command (not found)"; return 1; }
            # No -w: prints item attributes only, never the secret; discarded anyway.
            security find-generic-password -s "${KEYCHAIN_SERVICE}" >/dev/null 2>&1 \
                || { log_error "Keychain item not found: service '${KEYCHAIN_SERVICE}'"; return 1; }
            ;;
        file)
            [[ -f "${KEY_FILE_PATH}" ]] || { log_error "key file ${KEY_FILE_PATH}: not a regular file"; return 1; }
            local mode
            mode="$(stat -c %a "${KEY_FILE_PATH}" 2>/dev/null || stat -f %Lp "${KEY_FILE_PATH}" 2>/dev/null || echo unknown)"
            case "${mode}" in
                600|400) ;;
                *) log_error "key file ${KEY_FILE_PATH} has mode ${mode}; it must be 600 or 400"; return 1 ;;
            esac
            [[ -s "${KEY_FILE_PATH}" ]] || { log_error "key file ${KEY_FILE_PATH} is empty"; return 1; }
            ;;
        env) : ;;
        *) log_error "no NGC key source: pass --key-keychain SERVICE or --key-file PATH (or set NGC_API_KEY)"; return 1 ;;
    esac
}

# Writes the key to stdout (a pipe, never a terminal): first line, no newline.
# awk exits 3 on an empty key so pipefail stops the caller.
emit_key() {
    local first_line='NR == 1 { printf "%s", $0; n = length($0) } END { exit (n > 0 ? 0 : 3) }'
    case "${SOURCE_KIND}" in
        keychain) security find-generic-password -w -s "${KEYCHAIN_SERVICE}" | tr -d '\r' | awk "${first_line}" ;;
        file)     tr -d '\r' < "${KEY_FILE_PATH}" | awk "${first_line}" ;;
        env)      printf '%s\n' "${NGC_API_KEY}" | awk "${first_line}" ;;
        *)        return 1 ;;
    esac
}

label_secret() {
    kubectl label secret "$1" -n "${NAMESPACE}" --overwrite \
        "app.kubernetes.io/instance=${RELEASE}" "app.kubernetes.io/managed-by=nimble-oke-ngc-secrets" >/dev/null
}

delete_secret() {
    kubectl delete secret "$1" -n "${NAMESPACE}" --ignore-not-found >/dev/null
}

create_api() {
    delete_secret "${API_SECRET}"
    if ! emit_key | kubectl create secret generic "${API_SECRET}" -n "${NAMESPACE}" \
            --from-file=NGC_API_KEY=/dev/stdin >/dev/null; then
        delete_secret "${API_SECRET}" || true
        die "could not create Secret ${API_SECRET} (key source: ${SOURCE_KIND}; empty or unreadable key?)"
    fi
    label_secret "${API_SECRET}"
    log_success "Secret ${API_SECRET} created (key source: ${SOURCE_KIND}; value not shown)"
}

create_pull() {
    delete_secret "${PULL_SECRET}"
    # jq reads the key from stdin (-R raw) and builds the dockerconfigjson;
    # registry and user come in as --arg (neither is secret).
    if ! emit_key \
        | jq -Rjc --arg reg "${REGISTRY}" --arg user "${REGISTRY_USER}" \
             '{auths: {($reg): {username: $user, password: ., auth: (($user + ":" + .) | @base64)}}}' \
        | kubectl create secret generic "${PULL_SECRET}" -n "${NAMESPACE}" \
            --type=kubernetes.io/dockerconfigjson --from-file=.dockerconfigjson=/dev/stdin >/dev/null; then
        delete_secret "${PULL_SECRET}" || true
        die "could not create Secret ${PULL_SECRET} (key source: ${SOURCE_KIND}; empty or unreadable key?)"
    fi
    label_secret "${PULL_SECRET}"
    log_success "Secret ${PULL_SECRET} created (kubelet image pull only; value not shown)"
}

nimble_pin_kube_context

case "${ACTION}" in
    check)       check_source; log_success "NGC key source present: ${SOURCE_KIND} (value not read)" ;;
    create)      check_source; create_pull; create_api ;;
    create-pull) check_source; create_pull ;;
    create-api)  check_source; create_api ;;
    delete-api)  delete_secret "${API_SECRET}"; log_info "Secret ${API_SECRET} deleted (or absent)" ;;
    delete)      delete_secret "${API_SECRET}"; delete_secret "${PULL_SECRET}"
                 log_info "Secrets ${API_SECRET} and ${PULL_SECRET} deleted (or absent)" ;;
    -h|--help)   usage ;;
    *)           usage >&2; exit 2 ;;
esac
