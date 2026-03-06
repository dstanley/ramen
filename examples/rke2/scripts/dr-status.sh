#!/bin/bash
# Show DR status
# Usage: ./dr-status.sh [-w]
#
# Options:
#   -w    Watch mode (continuous updates)

set -e

NAMESPACE="${DR_NAMESPACE:-ramen-test}"
DRPC_NAME="${DRPC_NAME:-rto-rpo-test-drpc}"
HUB_CONTEXT="${HUB_CONTEXT:-rke2}"
WATCH_MODE=false

if [[ "$1" == "-w" || "$1" == "--watch" ]]; then
    WATCH_MODE=true
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

show_status() {
    clear 2>/dev/null || true
    echo -e "${BLUE}=== DR Status ===${NC}"
    echo "Time: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo ""

    # DRPC Status
    echo -e "${BLUE}DRPC: $DRPC_NAME${NC}"
    DRPC_JSON=$(kubectl --context "$HUB_CONTEXT" get drpc "$DRPC_NAME" -n "$NAMESPACE" -o json 2>/dev/null)
    if [[ -n "$DRPC_JSON" ]]; then
        PHASE=$(echo "$DRPC_JSON" | jq -r '.status.phase // "Unknown"')
        PROGRESSION=$(echo "$DRPC_JSON" | jq -r '.status.progression // "Unknown"')
        CLUSTER=$(echo "$DRPC_JSON" | jq -r '.status.preferredDecision.clusterName // "None"')
        ACTION=$(echo "$DRPC_JSON" | jq -r '.spec.action // "None"')
        PROTECTED=$(echo "$DRPC_JSON" | jq -r '.status.conditions[] | select(.type=="Protected") | .status' 2>/dev/null || echo "Unknown")

        echo "  Phase: $PHASE"
        echo "  Progression: $PROGRESSION"
        echo "  Current Cluster: $CLUSTER"
        echo "  Action: $ACTION"
        echo "  Protected: $PROTECTED"
    else
        echo -e "  ${RED}Not found${NC}"
    fi
    echo ""

    # PlacementDecision
    echo -e "${BLUE}PlacementDecision:${NC}"
    PLACEMENT=$(kubectl --context "$HUB_CONTEXT" get placementdecision -n "$NAMESPACE" \
        -l cluster.open-cluster-management.io/placement -o jsonpath='{.items[0].status.decisions[0].clusterName}' 2>/dev/null)
    echo "  Decision: ${PLACEMENT:-None}"
    echo ""

    # VRG Status on both clusters
    echo -e "${BLUE}VRG Status:${NC}"
    for cluster in harv marv; do
        VRG_STATUS=$(kubectl --context "$cluster" get vrg -n "$NAMESPACE" -o jsonpath='{.items[0].spec.replicationState}' 2>/dev/null || echo "NotFound")
        VRG_READY=$(kubectl --context "$cluster" get vrg -n "$NAMESPACE" -o jsonpath='{.items[0].status.conditions[?(@.type=="ClusterDataReady")].status}' 2>/dev/null || echo "-")
        echo "  $cluster: ReplicationState=$VRG_STATUS, DataReady=$VRG_READY"
    done
    echo ""

    # VolSync Status
    echo -e "${BLUE}VolSync Replication:${NC}"
    for cluster in harv marv; do
        RS=$(kubectl --context "$cluster" get replicationsource -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        RD=$(kubectl --context "$cluster" get replicationdestination -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        if [[ -n "$RS" ]]; then
            LAST_SYNC=$(kubectl --context "$cluster" get replicationsource "$RS" -n "$NAMESPACE" -o jsonpath='{.status.lastSyncTime}' 2>/dev/null || echo "-")
            echo "  $cluster: ReplicationSource ($RS), LastSync: $LAST_SYNC"
        fi
        if [[ -n "$RD" ]]; then
            LAST_SYNC=$(kubectl --context "$cluster" get replicationdestination "$RD" -n "$NAMESPACE" -o jsonpath='{.status.lastSyncTime}' 2>/dev/null || echo "-")
            echo "  $cluster: ReplicationDestination ($RD), LastSync: $LAST_SYNC"
        fi
        if [[ -z "$RS" && -z "$RD" ]]; then
            echo "  $cluster: No VolSync resources"
        fi
    done
    echo ""

    # App Status
    echo -e "${BLUE}Application Pods:${NC}"
    for cluster in harv marv; do
        POD_STATUS=$(kubectl --context "$cluster" get pods -n "$NAMESPACE" -l app=rto-rpo-test --no-headers 2>/dev/null | awk '{print $1 " (" $3 ")"}' || echo "")
        if [[ -n "$POD_STATUS" ]]; then
            echo -e "  $cluster: ${GREEN}$POD_STATUS${NC}"
        else
            echo "  $cluster: No pods"
        fi
    done
    echo ""

    # PVC Status
    echo -e "${BLUE}PVC Status:${NC}"
    for cluster in harv marv; do
        PVC_STATUS=$(kubectl --context "$cluster" get pvc rto-rpo-data -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{print $2 " (" $4 ")"}' || echo "NotFound")
        echo "  $cluster: $PVC_STATUS"
    done
}

if [[ "$WATCH_MODE" == "true" ]]; then
    while true; do
        show_status
        sleep 5
    done
else
    show_status
fi
