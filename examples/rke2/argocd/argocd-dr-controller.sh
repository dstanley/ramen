#!/bin/bash
# ArgoCD DR Controller
# Usage: ./argocd-dr-controller.sh
#
# This controller watches PlacementDecision changes and manages ArgoCD cluster
# labels to enable automatic application failover with the Cluster generator.
#
# How it works:
# 1. Watches PlacementDecision for the specified placement
# 2. When the decision changes, updates the ramen.dr/enabled label on cluster secrets
# 3. ArgoCD ApplicationSet (using Cluster generator) automatically deploys to labeled clusters
#
# This solves the limitation where ClusterDecisionResource generator only looks
# in the argocd namespace for PlacementDecisions.

set -e

NAMESPACE="${DR_NAMESPACE:-ramen-test}"
PLACEMENT_NAME="${PLACEMENT_NAME:-rto-rpo-test-placement}"
HUB_CONTEXT="${HUB_CONTEXT:-rke2}"
LABEL_KEY="${LABEL_KEY:-ramen.dr/enabled}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
LOG_FILE="/tmp/argocd-dr-controller.log"

LAST_CLUSTER=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() {
    local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1"
    echo -e "${GREEN}$msg${NC}"
    echo "$msg" >> "$LOG_FILE"
}

warn() {
    local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1"
    echo -e "${YELLOW}$msg${NC}"
    echo "$msg" >> "$LOG_FILE"
}

error() {
    local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1"
    echo -e "${RED}$msg${NC}"
    echo "$msg" >> "$LOG_FILE"
}

info() {
    local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1"
    echo -e "${CYAN}$msg${NC}"
    echo "$msg" >> "$LOG_FILE"
}

get_current_placement() {
    # During failover, PlacementDecision may contain two entries:
    # one with reason "RetainedForFailover" (old cluster) and the active target.
    # We need the non-retained cluster (the active placement target).
    local decisions
    decisions=$(kubectl --context "$HUB_CONTEXT" get placementdecision -n "$NAMESPACE" \
        -l cluster.open-cluster-management.io/placement="$PLACEMENT_NAME" \
        -o jsonpath='{range .items[0].status.decisions[*]}{.clusterName},{.reason}{"\n"}{end}' 2>/dev/null) || echo ""

    if [[ -z "$decisions" ]]; then
        echo ""
        return
    fi

    # Find the first decision that is NOT RetainedForFailover
    local active=""
    local first=""
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local name="${line%%,*}"
        local reason="${line#*,}"
        [[ -z "$first" ]] && first="$name"
        if [[ "$reason" != "RetainedForFailover" ]]; then
            active="$name"
            break
        fi
    done <<< "$decisions"

    # If all are retained (shouldn't happen), fall back to first
    echo "${active:-$first}"
}

get_all_clusters() {
    kubectl --context "$HUB_CONTEXT" get secrets -n "$ARGOCD_NAMESPACE" \
        -l argocd.argoproj.io/secret-type=cluster \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | sed 's/cluster-//'
}

get_labeled_cluster() {
    kubectl --context "$HUB_CONTEXT" get secrets -n "$ARGOCD_NAMESPACE" \
        -l argocd.argoproj.io/secret-type=cluster,"$LABEL_KEY"=true \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null | sed 's/cluster-//'
}

label_cluster() {
    local cluster=$1
    local secret_name="cluster-$cluster"

    log "Labeling cluster $cluster for ArgoCD deployment"
    kubectl --context "$HUB_CONTEXT" label secret "$secret_name" -n "$ARGOCD_NAMESPACE" \
        "$LABEL_KEY=true" --overwrite 2>/dev/null || true
}

unlabel_cluster() {
    local cluster=$1
    local secret_name="cluster-$cluster"

    log "Removing label from cluster $cluster"
    kubectl --context "$HUB_CONTEXT" label secret "$secret_name" -n "$ARGOCD_NAMESPACE" \
        "$LABEL_KEY-" 2>/dev/null || true
}

unlabel_all_clusters() {
    for cluster in $(get_all_clusters); do
        unlabel_cluster "$cluster"
    done
}

sync_labels() {
    local target_cluster=$1

    if [[ -z "$target_cluster" ]]; then
        warn "PlacementDecision is empty - unlabeling all clusters"
        unlabel_all_clusters
        return
    fi

    local current_labeled=$(get_labeled_cluster)

    if [[ "$current_labeled" == "$target_cluster" ]]; then
        # Already correct
        return
    fi

    log "Syncing labels: $current_labeled -> $target_cluster"

    # Remove label from all other clusters
    for cluster in $(get_all_clusters); do
        if [[ "$cluster" != "$target_cluster" ]]; then
            unlabel_cluster "$cluster"
        fi
    done

    # Add label to target cluster
    label_cluster "$target_cluster"
}

cleanup() {
    log "Shutting down ArgoCD DR controller..."
    exit 0
}

trap cleanup SIGINT SIGTERM

usage() {
    cat << EOF
Usage: $0 [options]

Options:
  --namespace NS        Namespace containing PlacementDecision (default: ramen-test)
  --placement NAME      Name of the Placement to watch (default: rto-rpo-test-placement)
  --label KEY           Label key to use on cluster secrets (default: ramen.dr/enabled)
  --context CTX         Kubectl context for hub cluster (default: rke2)
  --help                Show this help

Environment Variables:
  DR_NAMESPACE          Same as --namespace
  PLACEMENT_NAME        Same as --placement
  LABEL_KEY             Same as --label
  HUB_CONTEXT           Same as --context

Examples:
  # Start controller with defaults
  $0

  # Watch a specific placement
  $0 --namespace my-app --placement my-app-placement

  # Run in background
  nohup $0 > /tmp/argocd-dr-controller.log 2>&1 &
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --placement)
            PLACEMENT_NAME="$2"
            shift 2
            ;;
        --label)
            LABEL_KEY="$2"
            shift 2
            ;;
        --context)
            HUB_CONTEXT="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Main loop
echo ""
log "=== ArgoCD DR Controller Started ==="
info "Namespace: $NAMESPACE"
info "Placement: $PLACEMENT_NAME"
info "Label: $LABEL_KEY"
info "ArgoCD Namespace: $ARGOCD_NAMESPACE"
info "Log file: $LOG_FILE"
echo ""

# Initial sync
CURRENT_CLUSTER=$(get_current_placement)
if [[ -n "$CURRENT_CLUSTER" ]]; then
    log "Initial PlacementDecision: $CURRENT_CLUSTER"
    sync_labels "$CURRENT_CLUSTER"
    LAST_CLUSTER="$CURRENT_CLUSTER"
else
    warn "No PlacementDecision found initially"
fi

echo ""
log "Watching for PlacementDecision changes..."
echo ""

while true; do
    CURRENT_CLUSTER=$(get_current_placement)

    if [[ "$CURRENT_CLUSTER" != "$LAST_CLUSTER" ]]; then
        if [[ -z "$CURRENT_CLUSTER" ]]; then
            warn "*** PlacementDecision CLEARED ***"
            warn "This typically happens during Relocate quiesce phase"
        else
            log "*** PlacementDecision CHANGED: $LAST_CLUSTER -> $CURRENT_CLUSTER ***"
        fi

        sync_labels "$CURRENT_CLUSTER"
        LAST_CLUSTER="$CURRENT_CLUSTER"

        # Show current state
        echo ""
        info "Current ArgoCD cluster labels:"
        kubectl --context "$HUB_CONTEXT" get secrets -n "$ARGOCD_NAMESPACE" \
            -l argocd.argoproj.io/secret-type=cluster \
            -o custom-columns='CLUSTER:.metadata.name,DR_ENABLED:.metadata.labels.ramen\.dr/enabled' 2>/dev/null || true
        echo ""
    fi

    sleep 2
done
