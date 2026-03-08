#!/bin/bash
# Fleet DR Controller
# Usage: ./fleet-dr-controller.sh
#
# This controller watches PlacementDecision changes and manages Fleet cluster
# labels to enable automatic application failover with Fleet GitRepo targeting.
#
# How it works:
# 1. Watches PlacementDecision for the specified placement
# 2. When the decision changes, updates the ramen.dr/fleet-enabled label on
#    Fleet Cluster resources in the fleet-default namespace
# 3. Fleet GitRepo (using clusterSelector) automatically deploys to labeled clusters
#
# Fleet clusters use auto-generated IDs (e.g., c-npk9v) rather than friendly names.
# This controller resolves OCM cluster names (harv, marv) to Fleet cluster IDs
# using the management.cattle.io/cluster-display-name label.

set -e

NAMESPACE="${DR_NAMESPACE:-ramen-test}"
PLACEMENT_NAME="${PLACEMENT_NAME:-rto-rpo-test-placement}"
HUB_CONTEXT="${HUB_CONTEXT:-rke2}"
LABEL_KEY="${LABEL_KEY:-ramen.dr/fleet-enabled}"
FLEET_NAMESPACE="${FLEET_NAMESPACE:-fleet-default}"
LOG_FILE="/tmp/fleet-dr-controller.log"

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

# Resolve OCM cluster name (e.g., harv) to Fleet cluster ID (e.g., c-npk9v)
resolve_fleet_cluster_id() {
    local display_name=$1
    kubectl --context "$HUB_CONTEXT" get clusters.fleet.cattle.io -n "$FLEET_NAMESPACE" \
        -l "management.cattle.io/cluster-display-name=$display_name" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo ""
}

# Get display name for a Fleet cluster ID
get_display_name() {
    local fleet_id=$1
    kubectl --context "$HUB_CONTEXT" get clusters.fleet.cattle.io "$fleet_id" \
        -n "$FLEET_NAMESPACE" \
        -o jsonpath='{.metadata.labels.management\.cattle\.io/cluster-display-name}' 2>/dev/null || echo "$fleet_id"
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

get_all_fleet_clusters() {
    kubectl --context "$HUB_CONTEXT" get clusters.fleet.cattle.io -n "$FLEET_NAMESPACE" \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n'
}

get_labeled_fleet_cluster() {
    kubectl --context "$HUB_CONTEXT" get clusters.fleet.cattle.io -n "$FLEET_NAMESPACE" \
        -l "$LABEL_KEY=true" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo ""
}

label_fleet_cluster() {
    local ocm_name=$1
    local fleet_id
    fleet_id=$(resolve_fleet_cluster_id "$ocm_name")

    if [[ -z "$fleet_id" ]]; then
        error "Cannot resolve Fleet cluster ID for OCM cluster: $ocm_name"
        return 1
    fi

    log "Labeling Fleet cluster $fleet_id ($ocm_name) for deployment"
    kubectl --context "$HUB_CONTEXT" label clusters.fleet.cattle.io "$fleet_id" \
        -n "$FLEET_NAMESPACE" "$LABEL_KEY=true" --overwrite 2>/dev/null || true
}

unlabel_fleet_cluster() {
    local fleet_id=$1
    local display_name
    display_name=$(get_display_name "$fleet_id")

    log "Removing label from Fleet cluster $fleet_id ($display_name)"
    kubectl --context "$HUB_CONTEXT" label clusters.fleet.cattle.io "$fleet_id" \
        -n "$FLEET_NAMESPACE" "$LABEL_KEY-" 2>/dev/null || true
}

unlabel_all_fleet_clusters() {
    for fleet_id in $(get_all_fleet_clusters); do
        # Check if this cluster has the label before trying to remove
        local has_label
        has_label=$(kubectl --context "$HUB_CONTEXT" get clusters.fleet.cattle.io "$fleet_id" \
            -n "$FLEET_NAMESPACE" \
            -o jsonpath="{.metadata.labels.ramen\.dr/fleet-enabled}" 2>/dev/null || echo "")
        if [[ "$has_label" == "true" ]]; then
            unlabel_fleet_cluster "$fleet_id"
        fi
    done
}

sync_labels() {
    local target_cluster=$1

    if [[ -z "$target_cluster" ]]; then
        warn "PlacementDecision is empty - unlabeling all Fleet clusters"
        unlabel_all_fleet_clusters
        return
    fi

    local target_fleet_id
    target_fleet_id=$(resolve_fleet_cluster_id "$target_cluster")

    if [[ -z "$target_fleet_id" ]]; then
        error "Cannot resolve Fleet cluster ID for: $target_cluster"
        return 1
    fi

    local current_labeled
    current_labeled=$(get_labeled_fleet_cluster)

    if [[ "$current_labeled" == "$target_fleet_id" ]]; then
        return
    fi

    log "Syncing labels: $(get_display_name "$current_labeled") -> $target_cluster"

    # Remove label from all other clusters
    for fleet_id in $(get_all_fleet_clusters); do
        if [[ "$fleet_id" != "$target_fleet_id" ]]; then
            local has_label
            has_label=$(kubectl --context "$HUB_CONTEXT" get clusters.fleet.cattle.io "$fleet_id" \
                -n "$FLEET_NAMESPACE" \
                -o jsonpath="{.metadata.labels.ramen\.dr/fleet-enabled}" 2>/dev/null || echo "")
            if [[ "$has_label" == "true" ]]; then
                unlabel_fleet_cluster "$fleet_id"
            fi
        fi
    done

    # Add label to target cluster
    label_fleet_cluster "$target_cluster"
}

cleanup() {
    log "Shutting down Fleet DR controller..."
    exit 0
}

trap cleanup SIGINT SIGTERM

usage() {
    cat << EOF
Usage: $0 [options]

Options:
  --namespace NS        Namespace containing PlacementDecision (default: ramen-test)
  --placement NAME      Name of the Placement to watch (default: rto-rpo-test-placement)
  --label KEY           Label key to use on Fleet Cluster resources (default: ramen.dr/fleet-enabled)
  --context CTX         Kubectl context for hub cluster (default: rke2)
  --help                Show this help

Environment Variables:
  DR_NAMESPACE          Same as --namespace
  PLACEMENT_NAME        Same as --placement
  LABEL_KEY             Same as --label
  HUB_CONTEXT           Same as --context
  FLEET_NAMESPACE       Fleet namespace (default: fleet-default)

Examples:
  # Start controller with defaults
  $0

  # Watch a specific placement
  $0 --namespace my-app --placement my-app-placement

  # Run in background
  nohup $0 > /tmp/fleet-dr-controller.log 2>&1 &
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
log "=== Fleet DR Controller Started ==="
info "Namespace: $NAMESPACE"
info "Placement: $PLACEMENT_NAME"
info "Label: $LABEL_KEY"
info "Fleet Namespace: $FLEET_NAMESPACE"
info "Log file: $LOG_FILE"
echo ""

# Show cluster mapping
info "Fleet cluster mapping:"
kubectl --context "$HUB_CONTEXT" get clusters.fleet.cattle.io -n "$FLEET_NAMESPACE" \
    -o custom-columns='FLEET_ID:.metadata.name,DISPLAY_NAME:.metadata.labels.management\.cattle\.io/cluster-display-name' 2>/dev/null || true
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
        info "Current Fleet cluster labels:"
        kubectl --context "$HUB_CONTEXT" get clusters.fleet.cattle.io -n "$FLEET_NAMESPACE" \
            -o custom-columns='FLEET_ID:.metadata.name,DISPLAY_NAME:.metadata.labels.management\.cattle\.io/cluster-display-name,DR_ENABLED:.metadata.labels.ramen\.dr/fleet-enabled' 2>/dev/null || true
        echo ""
    fi

    sleep 2
done
