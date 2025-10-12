#!/usr/bin/env bash

# Verify local setup for Nimble OKE
# Run this before attempting any deployment

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

check_kubectl_installed() {
    if command -v kubectl &>/dev/null; then
        local version
        version=$(kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null | head -1 || echo "unknown")
        log_success "kubectl: installed ($version)"
        return 0
    else
        log_error "kubectl: NOT INSTALLED"
        log_info "Install: brew install kubectl"
        return 1
    fi
}

check_helm_installed() {
    if command -v helm &>/dev/null; then
        local version
        version=$(helm version --short 2>/dev/null || echo "unknown")
        log_success "Helm: installed ($version)"
        
        # Check minimum version (3.9+)
        local major minor
        major=$(echo "$version" | grep -oE 'v[0-9]+' | sed 's/v//' || echo "0")
        minor=$(echo "$version" | grep -oE '\.[0-9]+\.' | sed 's/\.//g' || echo "0")
        
        if [[ "$major" -ge 3 ]] && [[ "$minor" -ge 9 ]]; then
            log_success "Helm version meets minimum requirement (3.9+)"
        else
            log_warn "Helm version may be too old (need 3.9+, have $version)"
        fi
        return 0
    else
        log_error "Helm: NOT INSTALLED"
        log_info "Install: brew install helm"
        return 1
    fi
}

check_oci_installed() {
    if command -v oci &>/dev/null; then
        local version
        version=$(oci --version 2>/dev/null || echo "unknown")
        log_success "OCI CLI: installed ($version)"
        return 0
    else
        log_error "OCI CLI: NOT INSTALLED"
        log_info "Install: brew install oci-cli"
        return 1
    fi
}

check_jq_installed() {
    if command -v jq &>/dev/null; then
        local version
        version=$(jq --version 2>/dev/null || echo "unknown")
        log_success "jq: installed ($version)"
        return 0
    else
        log_error "jq: NOT INSTALLED"
        log_info "Install: brew install jq"
        return 1
    fi
}

check_bc_installed() {
    if command -v bc &>/dev/null; then
        local version
        version=$(bc --version 2>/dev/null | head -1 || echo "unknown")
        log_success "bc: installed ($version)"
        return 0
    else
        log_error "bc: NOT INSTALLED"
        log_info "Install: brew install bc"
        return 1
    fi
}

check_oci_config() {
    if [[ -f "$HOME/.oci/config" ]]; then
        log_success "OCI config file exists (~/.oci/config)"
        return 0
    else
        log_warn "OCI config file NOT FOUND (~/.oci/config)"
        log_info "Configure with: oci setup config"
        return 1
    fi
}

check_env_vars() {
    local missing=()
    
    if [[ -z "${NGC_API_KEY:-}" ]]; then
        missing+=("NGC_API_KEY")
    else
        log_success "NGC_API_KEY is set (${NGC_API_KEY:0:10}...)"
    fi
    
    if [[ -z "${OCI_COMPARTMENT_ID:-}" ]]; then
        missing+=("OCI_COMPARTMENT_ID")
    else
        log_success "OCI_COMPARTMENT_ID is set (${OCI_COMPARTMENT_ID:0:30}...)"
    fi
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "Missing environment variables: ${missing[*]}"
        log_info "Set with:"
        for var in "${missing[@]}"; do
            case "$var" in
                NGC_API_KEY)
                    echo "  export NGC_API_KEY=nvapi-your-key-here"
                    echo "  Get key from: https://ngc.nvidia.com/setup/api-key"
                    ;;
                OCI_COMPARTMENT_ID)
                    echo "  export OCI_COMPARTMENT_ID=ocid1.compartment..."
                    echo "  Find with: oci iam compartment list"
                    ;;
            esac
        done
        return 1
    fi
    
    return 0
}

generate_install_commands() {
    echo ""
    echo "==============================================================="
    echo "INSTALLATION COMMANDS (if needed)"
    echo "==============================================================="
    echo ""
    echo "Install missing tools with Homebrew:"
    echo ""
    echo "  # Install all at once"
    echo "  brew install kubectl helm oci-cli jq bc"
    echo ""
    echo "Or install individually:"
    echo "  brew install kubectl    # Kubernetes CLI"
    echo "  brew install helm       # Helm 3"
    echo "  brew install oci-cli    # Oracle Cloud CLI"
    echo "  brew install jq         # JSON processor"
    echo "  brew install bc         # Calculator"
    echo ""
    echo "After installing, configure OCI:"
    echo "  oci setup config"
    echo ""
    echo "Set required environment variables:"
    echo "  export NGC_API_KEY=nvapi-your-key-here"
    echo "  export OCI_COMPARTMENT_ID=ocid1.compartment..."
    echo ""
}

main() {
    log_info "Verifying local setup for Nimble OKE..."
    echo ""
    
    local failed=0
    
    echo "=== Required Tools ==="
    check_kubectl_installed || ((failed++))
    check_helm_installed || ((failed++))
    check_oci_installed || ((failed++))
    check_jq_installed || ((failed++))
    check_bc_installed || ((failed++))
    
    echo ""
    echo "=== OCI Configuration ==="
    check_oci_config || log_info "(Optional at this stage, needed before deployment)"
    
    echo ""
    echo "=== Environment Variables ==="
    check_env_vars || log_info "(Optional at this stage, needed before deployment)"
    
    echo ""
    if [[ $failed -eq 0 ]]; then
        log_success "✅ All required tools installed!"
        echo ""
        log_info "Next steps:"
        echo "  1. Configure OCI if not done: oci setup config"
        echo "  2. Set environment variables (NGC_API_KEY, OCI_COMPARTMENT_ID)"
        echo "  3. Run dry-run validation: make dry-run"
        return 0
    else
        log_error "❌ $failed tool(s) missing"
        generate_install_commands
        return 1
    fi
}

main "$@"

