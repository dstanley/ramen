#!/bin/bash

# SPDX-FileCopyrightText: The RamenDR authors
# SPDX-License-Identifier: Apache-2.0

# =============================================================================
# Ramen DR Teardown Script for RKE2 + Longhorn
# =============================================================================
#
# This script tears down a Ramen DR test environment on RKE2 clusters.
#
# Usage:
#   ./teardown-rke2-environment.sh              # Interactive teardown
#   ./teardown-rke2-environment.sh --force      # Skip confirmations
#   ./teardown-rke2-environment.sh --phase ocm  # Teardown specific phase
#
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION - Should match setup script
# =============================================================================

HUB_KUBECONFIG="${HUB_KUBECONFIG:-$HOME/.kube/hub-config}"
DR1_KUBECONFIG="${DR1_KUBECONFIG:-$HOME/.kube/dr1-config}"
DR2_KUBECONFIG="${DR2_KUBECONFIG:-$HOME/.kube/dr2-config}"

RAMEN_NAMESPACE="ramen-system"

# =============================================================================
# COLORS AND LOGGING
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

FORCE=false

confirm() {
    if [[ "$FORCE" == "true" ]]; then
        return 0
    fi

    local message="$1"
    echo -e "${YELLOW}${message}${NC}"
    read -r -p "Continue? [y/N] " response
    case "$response" in
        [yY][eE][sS]|[yY])
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

safe_delete() {
    local resource="$1"
    local kubeconfig="$2"
    local namespace="${3:-}"

    local ns_flag=""
    if [[ -n "$namespace" ]]; then
        ns_flag="-n $namespace"
    fi

    KUBECONFIG="$kubeconfig" kubectl delete $resource $ns_flag --ignore-not-found=true 2>/dev/null || true
}

check_kubeconfigs() {
    local missing=false

    for kc in "$HUB_KUBECONFIG" "$DR1_KUBECONFIG" "$DR2_KUBECONFIG"; do
        if [[ ! -f "$kc" ]]; then
            log_warn "Kubeconfig not found: $kc"
            missing=true
        fi
    done

    if [[ "$missing" == "true" ]]; then
        log_warn "Some kubeconfigs are missing. Continuing with available clusters..."
    fi
}

# =============================================================================
# PHASE: REMOVE RAMEN
# =============================================================================

teardown_ramen() {
    log_info "=========================================="
    log_info "Phase: Removing Ramen"
    log_info "=========================================="

    # Remove DRPlacementControls first (workload protection)
    log_info "Removing DRPlacementControls..."
    if [[ -f "$HUB_KUBECONFIG" ]]; then
        KUBECONFIG="$HUB_KUBECONFIG" kubectl get drpc -A --no-headers 2>/dev/null | while read -r ns name _; do
            log_info "  Removing DRPC $name in $ns..."
            KUBECONFIG="$HUB_KUBECONFIG" kubectl delete drpc "$name" -n "$ns" --timeout=60s 2>/dev/null || true
        done
    fi

    # Remove DRPolicy
    log_info "Removing DRPolicy..."
    if [[ -f "$HUB_KUBECONFIG" ]]; then
        safe_delete "drpolicy --all" "$HUB_KUBECONFIG"
    fi

    # Remove DRClusters
    log_info "Removing DRClusters..."
    if [[ -f "$HUB_KUBECONFIG" ]]; then
        safe_delete "drcluster --all" "$HUB_KUBECONFIG"
    fi

    # Remove Ramen hub operator
    log_info "Removing Ramen hub operator..."
    if [[ -f "$HUB_KUBECONFIG" ]]; then
        KUBECONFIG="$HUB_KUBECONFIG" kubectl delete -k "https://github.com/RamenDR/ramen/config/olm-install/hub?ref=main" --ignore-not-found=true 2>/dev/null || true
    fi

    # Remove Ramen DR cluster operators
    log_info "Removing Ramen DR cluster catalog..."
    for ctx in dr1 dr2; do
        local kc_var="${ctx^^}_KUBECONFIG"
        local kc="${!kc_var}"

        if [[ -f "$kc" ]]; then
            KUBECONFIG="$kc" kubectl delete -k "https://github.com/RamenDR/ramen/config/olm-install/base?ref=main" --ignore-not-found=true 2>/dev/null || true
        fi
    done

    # Remove S3 secrets
    log_info "Removing S3 secrets..."
    for ctx in hub dr1 dr2; do
        local kc_var="${ctx^^}_KUBECONFIG"
        local kc="${!kc_var}"

        if [[ -f "$kc" ]]; then
            safe_delete "secret s3-secret" "$kc" "$RAMEN_NAMESPACE"
        fi
    done

    # Remove Ramen namespace
    log_info "Removing Ramen namespace..."
    for ctx in hub dr1 dr2; do
        local kc_var="${ctx^^}_KUBECONFIG"
        local kc="${!kc_var}"

        if [[ -f "$kc" ]]; then
            safe_delete "namespace $RAMEN_NAMESPACE" "$kc"
        fi
    done

    # Remove Ramen CRDs
    log_info "Removing Ramen CRDs..."
    if [[ -f "$HUB_KUBECONFIG" ]]; then
        for crd in drplacementcontrols.ramendr.openshift.io drpolicies.ramendr.openshift.io drclusters.ramendr.openshift.io volumereplicationgroups.ramendr.openshift.io; do
            safe_delete "crd $crd" "$HUB_KUBECONFIG"
        done
    fi

    log_success "Ramen removal complete"
}

# =============================================================================
# PHASE: REMOVE VOLSYNC
# =============================================================================

teardown_volsync() {
    log_info "=========================================="
    log_info "Phase: Removing VolSync"
    log_info "=========================================="

    for ctx in dr1 dr2; do
        local kc_var="${ctx^^}_KUBECONFIG"
        local kc="${!kc_var}"

        if [[ -f "$kc" ]]; then
            log_info "Removing VolSync from $ctx..."

            # Delete VolSync resources
            KUBECONFIG="$kc" kubectl delete replicationsource --all -A --ignore-not-found=true 2>/dev/null || true
            KUBECONFIG="$kc" kubectl delete replicationdestination --all -A --ignore-not-found=true 2>/dev/null || true

            # Delete VolSync deployment
            KUBECONFIG="$kc" kubectl delete -f "https://raw.githubusercontent.com/backube/volsync/release-0.10/deploy/manifests/volsync.yaml" --ignore-not-found=true 2>/dev/null || true
        fi
    done

    log_success "VolSync removal complete"
}

# =============================================================================
# PHASE: REMOVE VELERO
# =============================================================================

teardown_velero() {
    log_info "=========================================="
    log_info "Phase: Removing Velero"
    log_info "=========================================="

    for ctx in dr1 dr2; do
        local kc_var="${ctx^^}_KUBECONFIG"
        local kc="${!kc_var}"

        if [[ -f "$kc" ]]; then
            log_info "Removing Velero from $ctx..."

            # Delete backups first
            KUBECONFIG="$kc" kubectl delete backup --all -n velero --ignore-not-found=true 2>/dev/null || true
            KUBECONFIG="$kc" kubectl delete restore --all -n velero --ignore-not-found=true 2>/dev/null || true

            # Uninstall Velero
            if command -v velero &>/dev/null; then
                velero uninstall --kubeconfig "$kc" --force 2>/dev/null || true
            else
                # Manual removal
                safe_delete "namespace velero" "$kc"
                safe_delete "clusterrolebinding velero" "$kc"
                safe_delete "clusterrole velero" "$kc"
            fi
        fi
    done

    log_success "Velero removal complete"
}

# =============================================================================
# PHASE: REMOVE MINIO
# =============================================================================

teardown_minio() {
    log_info "=========================================="
    log_info "Phase: Removing MinIO"
    log_info "=========================================="

    if [[ -f "$HUB_KUBECONFIG" ]]; then
        log_info "Removing MinIO from hub..."
        safe_delete "namespace minio" "$HUB_KUBECONFIG"

        # Remove mc alias if mc is installed
        if command -v mc &>/dev/null; then
            mc alias remove ramen-minio 2>/dev/null || true
        fi
    fi

    # Remove temp file
    rm -f /tmp/ramen-minio-endpoint

    log_success "MinIO removal complete"
}

# =============================================================================
# PHASE: REMOVE EXTERNAL SNAPSHOTTER
# =============================================================================

teardown_snapshotter() {
    log_info "=========================================="
    log_info "Phase: Removing External Snapshotter"
    log_info "=========================================="

    local base_url="https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/release-8.0"

    for ctx in dr1 dr2; do
        local kc_var="${ctx^^}_KUBECONFIG"
        local kc="${!kc_var}"

        if [[ -f "$kc" ]]; then
            log_info "Removing external-snapshotter from $ctx..."

            # Remove controller
            KUBECONFIG="$kc" kubectl delete -f "${base_url}/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml" --ignore-not-found=true 2>/dev/null || true
            KUBECONFIG="$kc" kubectl delete -f "${base_url}/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml" --ignore-not-found=true 2>/dev/null || true

            # Note: Not removing CRDs as they may be used by other components
            log_warn "  Snapshot CRDs preserved (may be used by Longhorn)"
        fi
    done

    log_success "External snapshotter removal complete"
}

# =============================================================================
# PHASE: REMOVE LONGHORN CONFIG
# =============================================================================

teardown_longhorn_config() {
    log_info "=========================================="
    log_info "Phase: Removing Longhorn Ramen Configuration"
    log_info "=========================================="

    for ctx in dr1 dr2; do
        local kc_var="${ctx^^}_KUBECONFIG"
        local kc="${!kc_var}"

        if [[ -f "$kc" ]]; then
            log_info "Removing Ramen StorageClass from $ctx..."
            safe_delete "storageclass longhorn-ramen" "$kc"
            safe_delete "volumesnapshotclass longhorn-snapshot" "$kc"
        fi
    done

    log_warn "Longhorn itself was NOT removed (only Ramen-specific config)"

    log_success "Longhorn config removal complete"
}

# =============================================================================
# PHASE: REMOVE OCM
# =============================================================================

teardown_ocm() {
    log_info "=========================================="
    log_info "Phase: Removing Open Cluster Management"
    log_info "=========================================="

    # Unjoin managed clusters
    for ctx in dr1 dr2; do
        local kc_var="${ctx^^}_KUBECONFIG"
        local kc="${!kc_var}"

        if [[ -f "$kc" ]]; then
            log_info "Unjoining $ctx from hub..."

            # Remove klusterlet
            if command -v clusteradm &>/dev/null; then
                KUBECONFIG="$kc" clusteradm unjoin --cluster-name "$ctx" 2>/dev/null || true
            fi

            # Manual cleanup
            KUBECONFIG="$kc" kubectl delete namespace open-cluster-management-agent --ignore-not-found=true 2>/dev/null || true
            KUBECONFIG="$kc" kubectl delete namespace open-cluster-management-agent-addon --ignore-not-found=true 2>/dev/null || true
        fi
    done

    # Remove managed cluster registrations from hub
    if [[ -f "$HUB_KUBECONFIG" ]]; then
        log_info "Removing managed cluster registrations..."
        safe_delete "managedcluster dr1" "$HUB_KUBECONFIG"
        safe_delete "managedcluster dr2" "$HUB_KUBECONFIG"

        # Clean up hub
        log_info "Cleaning up OCM hub..."
        if command -v clusteradm &>/dev/null; then
            KUBECONFIG="$HUB_KUBECONFIG" clusteradm clean 2>/dev/null || true
        fi

        # Manual cleanup
        KUBECONFIG="$HUB_KUBECONFIG" kubectl delete namespace open-cluster-management-hub --ignore-not-found=true 2>/dev/null || true
        KUBECONFIG="$HUB_KUBECONFIG" kubectl delete namespace open-cluster-management --ignore-not-found=true 2>/dev/null || true
    fi

    log_success "OCM removal complete"
}

# =============================================================================
# PHASE: REMOVE OLM
# =============================================================================

teardown_olm() {
    log_info "=========================================="
    log_info "Phase: Removing OLM"
    log_info "=========================================="

    for ctx in hub dr1 dr2; do
        local kc_var="${ctx^^}_KUBECONFIG"
        local kc="${!kc_var}"

        if [[ -f "$kc" ]]; then
            log_info "Removing OLM from $ctx..."

            # Delete OLM namespaces
            safe_delete "namespace olm" "$kc"
            safe_delete "namespace operators" "$kc"

            # Delete OLM CRDs
            KUBECONFIG="$kc" kubectl delete crd -l olm.operatorframework.io/managed=true --ignore-not-found=true 2>/dev/null || true
        fi
    done

    log_success "OLM removal complete"
}

# =============================================================================
# PHASE: CLEANUP E2E CONFIG
# =============================================================================

cleanup_e2e_config() {
    log_info "=========================================="
    log_info "Phase: Cleaning up E2E Config"
    log_info "=========================================="

    local config_file="${HOME}/ramen-e2e-config.yaml"

    if [[ -f "$config_file" ]]; then
        rm -f "$config_file"
        log_info "Removed $config_file"
    fi

    log_success "E2E config cleanup complete"
}

# =============================================================================
# FULL TEARDOWN
# =============================================================================

teardown_all() {
    log_info "=========================================="
    log_info "FULL ENVIRONMENT TEARDOWN"
    log_info "=========================================="
    echo ""
    log_warn "This will remove:"
    echo "  - Ramen operators and DR resources"
    echo "  - VolSync"
    echo "  - Velero and all backups"
    echo "  - MinIO and all data"
    echo "  - External snapshotter"
    echo "  - Longhorn Ramen configuration (not Longhorn itself)"
    echo "  - OCM hub and managed cluster registrations"
    echo "  - OLM (optional)"
    echo ""

    if ! confirm "Are you sure you want to proceed?"; then
        log_info "Teardown cancelled"
        exit 0
    fi

    teardown_ramen
    teardown_volsync
    teardown_velero
    teardown_minio
    teardown_snapshotter
    teardown_longhorn_config
    teardown_ocm
    cleanup_e2e_config

    # Optionally remove OLM
    echo ""
    if confirm "Also remove OLM? (Usually not needed)"; then
        teardown_olm
    fi

    log_success "=========================================="
    log_success "Full teardown complete!"
    log_success "=========================================="
}

# =============================================================================
# MAIN
# =============================================================================

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --phase PHASE    Teardown specific phase only. Available phases:
                   ramen, volsync, velero, minio, snapshotter, longhorn-config, ocm, olm, e2e-config, all
  --force          Skip confirmation prompts
  --help           Show this help message

Environment Variables:
  HUB_KUBECONFIG   Path to hub cluster kubeconfig (default: ~/.kube/hub-config)
  DR1_KUBECONFIG   Path to dr1 cluster kubeconfig (default: ~/.kube/dr1-config)
  DR2_KUBECONFIG   Path to dr2 cluster kubeconfig (default: ~/.kube/dr2-config)

Examples:
  # Full teardown (interactive)
  $0

  # Full teardown (skip confirmations)
  $0 --force

  # Remove only Ramen
  $0 --phase ramen

  # Remove Ramen and Velero
  $0 --phase ramen --force && $0 --phase velero --force
EOF
}

main() {
    local phase="all"

    while [[ $# -gt 0 ]]; do
        case $1 in
            --phase)
                phase="$2"
                shift 2
                ;;
            --force)
                FORCE=true
                shift
                ;;
            --help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    echo ""
    echo "=============================================="
    echo "  Ramen DR Teardown for RKE2 + Longhorn"
    echo "=============================================="
    echo ""

    check_kubeconfigs

    case $phase in
        all)
            teardown_all
            ;;
        ramen)
            if confirm "Remove Ramen operators and DR resources?"; then
                teardown_ramen
            fi
            ;;
        volsync)
            if confirm "Remove VolSync?"; then
                teardown_volsync
            fi
            ;;
        velero)
            if confirm "Remove Velero and all backups?"; then
                teardown_velero
            fi
            ;;
        minio)
            if confirm "Remove MinIO and all data?"; then
                teardown_minio
            fi
            ;;
        snapshotter)
            if confirm "Remove external snapshotter?"; then
                teardown_snapshotter
            fi
            ;;
        longhorn-config)
            if confirm "Remove Longhorn Ramen configuration?"; then
                teardown_longhorn_config
            fi
            ;;
        ocm)
            if confirm "Remove OCM (this will disconnect managed clusters)?"; then
                teardown_ocm
            fi
            ;;
        olm)
            if confirm "Remove OLM?"; then
                teardown_olm
            fi
            ;;
        e2e-config)
            cleanup_e2e_config
            ;;
        *)
            log_error "Unknown phase: $phase"
            usage
            exit 1
            ;;
    esac
}

main "$@"
