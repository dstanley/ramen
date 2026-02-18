#!/bin/bash

# SPDX-FileCopyrightText: The RamenDR authors
# SPDX-License-Identifier: Apache-2.0

# =============================================================================
# Ramen DR Setup Script for RKE2 + Longhorn
# =============================================================================
#
# This script sets up a complete Ramen DR test environment on RKE2 clusters.
#
# Prerequisites:
#   - 3 RKE2 clusters (hub, dr1, dr2) already running
#   - Longhorn installed on dr1 and dr2
#   - Network connectivity between all clusters
#   - kubectl, clusteradm, velero, mc (minio client) installed locally
#
# Usage:
#   1. Copy this script and edit the CONFIGURATION section below
#   2. Run: ./setup-rke2-environment.sh
#   3. Or run specific phases: ./setup-rke2-environment.sh --phase ocm
#
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION - Edit these values for your environment
# =============================================================================

# Cluster kubeconfig paths
HUB_KUBECONFIG="${HUB_KUBECONFIG:-$HOME/.kube/hub-config}"
DR1_KUBECONFIG="${DR1_KUBECONFIG:-$HOME/.kube/dr1-config}"
DR2_KUBECONFIG="${DR2_KUBECONFIG:-$HOME/.kube/dr2-config}"

# Cluster API server IPs (used for OCM join)
HUB_API_SERVER="${HUB_API_SERVER:-}"  # e.g., https://192.168.1.10:6443

# MinIO configuration
MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY:-minio}"
MINIO_SECRET_KEY="${MINIO_SECRET_KEY:-minio123}"
MINIO_BUCKET="${MINIO_BUCKET:-ramen}"
MINIO_NODEPORT="${MINIO_NODEPORT:-30000}"

# Ramen configuration
RAMEN_NAMESPACE="ramen-system"
DR_POLICY_NAME="dr-policy"
SCHEDULING_INTERVAL="5m"

# Component versions
EXTERNAL_SNAPSHOTTER_VERSION="8.0"
VELERO_VERSION="v1.14.0"
VELERO_PLUGIN_VERSION="v1.10.0"
VOLSYNC_VERSION="0.10"
LONGHORN_VERSION="v1.7.2"

# =============================================================================
# COLORS AND LOGGING
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

check_prerequisites() {
    log_info "Checking prerequisites..."

    local missing=()

    command -v kubectl &>/dev/null || missing+=("kubectl")
    command -v clusteradm &>/dev/null || missing+=("clusteradm")
    command -v velero &>/dev/null || missing+=("velero")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        echo ""
        echo "Install missing tools:"
        echo "  kubectl:    curl -LO https://dl.k8s.io/release/\$(curl -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
        echo "  clusteradm: curl -L https://raw.githubusercontent.com/open-cluster-management-io/clusteradm/main/install.sh | bash"
        echo "  velero:     curl -L https://github.com/vmware-tanzu/velero/releases/download/${VELERO_VERSION}/velero-${VELERO_VERSION}-linux-amd64.tar.gz | tar xz"
        exit 1
    fi

    # Check kubeconfigs exist
    for kc in "$HUB_KUBECONFIG" "$DR1_KUBECONFIG" "$DR2_KUBECONFIG"; do
        if [[ ! -f "$kc" ]]; then
            log_error "Kubeconfig not found: $kc"
            exit 1
        fi
    done

    # Check cluster connectivity
    for ctx in hub dr1 dr2; do
        local kc_var="${ctx^^}_KUBECONFIG"
        local kc="${!kc_var}"
        if ! KUBECONFIG="$kc" kubectl cluster-info &>/dev/null; then
            log_error "Cannot connect to $ctx cluster using $kc"
            exit 1
        fi
    done

    log_success "All prerequisites satisfied"
}

wait_for_deployment() {
    local namespace=$1
    local deployment=$2
    local kubeconfig=$3
    local timeout=${4:-300}

    log_info "Waiting for deployment $deployment in $namespace..."
    KUBECONFIG="$kubeconfig" kubectl rollout status deployment/"$deployment" \
        -n "$namespace" --timeout="${timeout}s" || {
        log_error "Deployment $deployment failed to become ready"
        return 1
    }
}

get_hub_ip() {
    if [[ -n "$HUB_API_SERVER" ]]; then
        echo "$HUB_API_SERVER"
        return
    fi

    # Extract from kubeconfig
    local server
    server=$(KUBECONFIG="$HUB_KUBECONFIG" kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
    echo "$server"
}

# =============================================================================
# PHASE: INSTALL OCM
# =============================================================================

install_ocm() {
    log_info "=========================================="
    log_info "Phase: Installing Open Cluster Management"
    log_info "=========================================="

    local hub_api
    hub_api=$(get_hub_ip)

    if [[ -z "$hub_api" ]]; then
        log_error "Could not determine hub API server. Set HUB_API_SERVER environment variable."
        exit 1
    fi

    log_info "Hub API Server: $hub_api"

    # Initialize OCM hub
    log_info "Initializing OCM hub..."
    KUBECONFIG="$HUB_KUBECONFIG" clusteradm init --wait

    # Get join token
    log_info "Getting join token..."
    local token
    token=$(KUBECONFIG="$HUB_KUBECONFIG" clusteradm get token | grep -oP 'token=\K[^ ]+' | head -1)

    if [[ -z "$token" ]]; then
        log_error "Failed to get OCM join token"
        exit 1
    fi

    # Join dr1
    log_info "Joining dr1 to hub..."
    KUBECONFIG="$DR1_KUBECONFIG" clusteradm join \
        --hub-token "$token" \
        --hub-apiserver "$hub_api" \
        --cluster-name dr1 \
        --wait || true  # May fail if already joined

    # Join dr2
    log_info "Joining dr2 to hub..."
    KUBECONFIG="$DR2_KUBECONFIG" clusteradm join \
        --hub-token "$token" \
        --hub-apiserver "$hub_api" \
        --cluster-name dr2 \
        --wait || true

    # Accept clusters
    log_info "Accepting managed clusters..."
    sleep 10  # Wait for CSRs
    KUBECONFIG="$HUB_KUBECONFIG" clusteradm accept --clusters dr1,dr2 || true

    # Verify
    log_info "Verifying OCM setup..."
    sleep 5
    KUBECONFIG="$HUB_KUBECONFIG" kubectl get managedclusters

    log_success "OCM installation complete"
}

# =============================================================================
# PHASE: CONFIGURE LONGHORN
# =============================================================================

configure_longhorn() {
    log_info "=========================================="
    log_info "Phase: Configuring Longhorn for Ramen"
    log_info "=========================================="

    local storageclass_yaml='
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn-ramen
  labels:
    ramendr.openshift.io/storageid: "longhorn"
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: Immediate
parameters:
  numberOfReplicas: "2"
  staleReplicaTimeout: "2880"
  fsType: "ext4"
---
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: longhorn-snapshot
  labels:
    ramendr.openshift.io/storageid: "longhorn"
driver: driver.longhorn.io
deletionPolicy: Delete
parameters:
  type: snap
'

    for ctx in dr1 dr2; do
        local kc_var="${ctx^^}_KUBECONFIG"
        local kc="${!kc_var}"

        log_info "Configuring Longhorn on $ctx..."

        # Check if Longhorn is installed
        if ! KUBECONFIG="$kc" kubectl get ns longhorn-system &>/dev/null; then
            log_warn "Longhorn not found on $ctx, installing..."
            KUBECONFIG="$kc" kubectl apply -f "https://raw.githubusercontent.com/longhorn/longhorn/${LONGHORN_VERSION}/deploy/longhorn.yaml"
            wait_for_deployment "longhorn-system" "longhorn-manager" "$kc" 600
        fi

        # Apply StorageClass and VolumeSnapshotClass
        echo "$storageclass_yaml" | KUBECONFIG="$kc" kubectl apply -f -
    done

    log_success "Longhorn configuration complete"
}

# =============================================================================
# PHASE: INSTALL EXTERNAL SNAPSHOTTER
# =============================================================================

install_snapshotter() {
    log_info "=========================================="
    log_info "Phase: Installing External Snapshotter"
    log_info "=========================================="

    local base_url="https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/release-${EXTERNAL_SNAPSHOTTER_VERSION}"

    for ctx in dr1 dr2; do
        local kc_var="${ctx^^}_KUBECONFIG"
        local kc="${!kc_var}"

        log_info "Installing external-snapshotter on $ctx..."

        # CRDs
        KUBECONFIG="$kc" kubectl apply -f "${base_url}/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml"
        KUBECONFIG="$kc" kubectl apply -f "${base_url}/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml"
        KUBECONFIG="$kc" kubectl apply -f "${base_url}/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml"

        # Controller
        KUBECONFIG="$kc" kubectl apply -f "${base_url}/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml"
        KUBECONFIG="$kc" kubectl apply -f "${base_url}/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml"

        wait_for_deployment "kube-system" "snapshot-controller" "$kc" 120
    done

    log_success "External snapshotter installation complete"
}

# =============================================================================
# PHASE: INSTALL MINIO
# =============================================================================

install_minio() {
    log_info "=========================================="
    log_info "Phase: Installing MinIO on Hub"
    log_info "=========================================="

    local minio_yaml="
apiVersion: v1
kind: Namespace
metadata:
  name: minio
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: minio-pvc
  namespace: minio
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  namespace: minio
spec:
  replicas: 1
  selector:
    matchLabels:
      app: minio
  template:
    metadata:
      labels:
        app: minio
    spec:
      containers:
      - name: minio
        image: minio/minio:latest
        args: [\"server\", \"/data\", \"--console-address\", \":9001\"]
        env:
        - name: MINIO_ROOT_USER
          value: \"${MINIO_ACCESS_KEY}\"
        - name: MINIO_ROOT_PASSWORD
          value: \"${MINIO_SECRET_KEY}\"
        ports:
        - containerPort: 9000
          name: api
        - containerPort: 9001
          name: console
        volumeMounts:
        - name: data
          mountPath: /data
        readinessProbe:
          httpGet:
            path: /minio/health/ready
            port: 9000
          initialDelaySeconds: 10
          periodSeconds: 5
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: minio-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: minio
  namespace: minio
spec:
  type: NodePort
  ports:
  - port: 9000
    targetPort: 9000
    nodePort: ${MINIO_NODEPORT}
    name: api
  - port: 9001
    targetPort: 9001
    nodePort: $((MINIO_NODEPORT + 1))
    name: console
  selector:
    app: minio
"

    log_info "Deploying MinIO..."
    echo "$minio_yaml" | KUBECONFIG="$HUB_KUBECONFIG" kubectl apply -f -

    wait_for_deployment "minio" "minio" "$HUB_KUBECONFIG" 120

    # Get MinIO endpoint
    local hub_ip
    hub_ip=$(KUBECONFIG="$HUB_KUBECONFIG" kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
    local minio_endpoint="http://${hub_ip}:${MINIO_NODEPORT}"

    log_info "MinIO endpoint: $minio_endpoint"
    log_info "MinIO console: http://${hub_ip}:$((MINIO_NODEPORT + 1))"

    # Create bucket using mc if available
    if command -v mc &>/dev/null; then
        log_info "Creating MinIO bucket..."
        sleep 5  # Wait for MinIO to be fully ready
        mc alias set ramen-minio "$minio_endpoint" "$MINIO_ACCESS_KEY" "$MINIO_SECRET_KEY" || true
        mc mb "ramen-minio/${MINIO_BUCKET}" --ignore-existing || true
    else
        log_warn "mc (MinIO client) not found. Create bucket '${MINIO_BUCKET}' manually via console."
    fi

    # Save endpoint for later use
    echo "$minio_endpoint" > /tmp/ramen-minio-endpoint

    log_success "MinIO installation complete"
}

# =============================================================================
# PHASE: INSTALL VELERO
# =============================================================================

install_velero() {
    log_info "=========================================="
    log_info "Phase: Installing Velero"
    log_info "=========================================="

    # Get MinIO endpoint
    local minio_endpoint
    if [[ -f /tmp/ramen-minio-endpoint ]]; then
        minio_endpoint=$(cat /tmp/ramen-minio-endpoint)
    else
        local hub_ip
        hub_ip=$(KUBECONFIG="$HUB_KUBECONFIG" kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
        minio_endpoint="http://${hub_ip}:${MINIO_NODEPORT}"
    fi

    log_info "Using MinIO endpoint: $minio_endpoint"

    # Create credentials file
    local creds_file
    creds_file=$(mktemp)
    cat > "$creds_file" <<EOF
[default]
aws_access_key_id = ${MINIO_ACCESS_KEY}
aws_secret_access_key = ${MINIO_SECRET_KEY}
EOF

    for ctx in dr1 dr2; do
        local kc_var="${ctx^^}_KUBECONFIG"
        local kc="${!kc_var}"

        log_info "Installing Velero on $ctx..."

        velero install \
            --kubeconfig "$kc" \
            --provider aws \
            --plugins "velero/velero-plugin-for-aws:${VELERO_PLUGIN_VERSION}" \
            --bucket "$MINIO_BUCKET" \
            --secret-file "$creds_file" \
            --backup-location-config "region=minio,s3ForcePathStyle=true,s3Url=${minio_endpoint}" \
            --use-volume-snapshots=false \
            --wait || {
            log_warn "Velero install returned error on $ctx (may already be installed)"
        }
    done

    rm -f "$creds_file"

    log_success "Velero installation complete"
}

# =============================================================================
# PHASE: INSTALL VOLSYNC
# =============================================================================

install_volsync() {
    log_info "=========================================="
    log_info "Phase: Installing VolSync"
    log_info "=========================================="

    for ctx in dr1 dr2; do
        local kc_var="${ctx^^}_KUBECONFIG"
        local kc="${!kc_var}"

        log_info "Installing VolSync on $ctx..."

        KUBECONFIG="$kc" kubectl apply -f "https://raw.githubusercontent.com/backube/volsync/release-${VOLSYNC_VERSION}/deploy/manifests/volsync.yaml"

        wait_for_deployment "volsync-system" "volsync" "$kc" 120 || true
    done

    log_success "VolSync installation complete"
}

# =============================================================================
# PHASE: INSTALL RAMEN
# =============================================================================

install_ramen() {
    log_info "=========================================="
    log_info "Phase: Installing Ramen Operators"
    log_info "=========================================="

    # Install OLM if not present
    for ctx in hub dr1 dr2; do
        local kc_var="${ctx^^}_KUBECONFIG"
        local kc="${!kc_var}"

        if ! KUBECONFIG="$kc" kubectl get ns olm &>/dev/null; then
            log_info "Installing OLM on $ctx..."
            curl -sL https://github.com/operator-framework/operator-lifecycle-manager/releases/download/v0.28.0/install.sh | KUBECONFIG="$kc" bash -s v0.28.0 || true
        fi
    done

    # Create ramen-system namespace
    for ctx in hub dr1 dr2; do
        local kc_var="${ctx^^}_KUBECONFIG"
        local kc="${!kc_var}"

        KUBECONFIG="$kc" kubectl create namespace "$RAMEN_NAMESPACE" --dry-run=client -o yaml | \
            KUBECONFIG="$kc" kubectl apply -f -
    done

    # Install hub operator
    log_info "Installing Ramen hub operator..."
    KUBECONFIG="$HUB_KUBECONFIG" kubectl apply -k "https://github.com/RamenDR/ramen/config/olm-install/hub?ref=main"

    # Install DR cluster catalog source
    log_info "Installing Ramen DR cluster catalog..."
    for ctx in dr1 dr2; do
        local kc_var="${ctx^^}_KUBECONFIG"
        local kc="${!kc_var}"

        KUBECONFIG="$kc" kubectl apply -k "https://github.com/RamenDR/ramen/config/olm-install/base?ref=main"
    done

    # Wait for hub operator
    sleep 30
    log_info "Waiting for Ramen hub operator..."
    KUBECONFIG="$HUB_KUBECONFIG" kubectl wait --for=condition=Available deployment -l app=ramen-hub \
        -n "$RAMEN_NAMESPACE" --timeout=300s || {
        log_warn "Hub operator may still be starting..."
    }

    log_success "Ramen operators installation complete"
}

# =============================================================================
# PHASE: CONFIGURE RAMEN
# =============================================================================

configure_ramen() {
    log_info "=========================================="
    log_info "Phase: Configuring Ramen DR Resources"
    log_info "=========================================="

    # Get MinIO endpoint
    local minio_endpoint
    local hub_ip
    hub_ip=$(KUBECONFIG="$HUB_KUBECONFIG" kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
    minio_endpoint="http://${hub_ip}:${MINIO_NODEPORT}"

    # Create S3 secret on all clusters
    log_info "Creating S3 secrets..."
    for ctx in hub dr1 dr2; do
        local kc_var="${ctx^^}_KUBECONFIG"
        local kc="${!kc_var}"

        KUBECONFIG="$kc" kubectl create secret generic s3-secret \
            -n "$RAMEN_NAMESPACE" \
            --from-literal=AWS_ACCESS_KEY_ID="$MINIO_ACCESS_KEY" \
            --from-literal=AWS_SECRET_ACCESS_KEY="$MINIO_SECRET_KEY" \
            --dry-run=client -o yaml | KUBECONFIG="$kc" kubectl apply -f -
    done

    # Create DRCluster and DRPolicy
    log_info "Creating DR resources..."
    local dr_resources="
apiVersion: ramendr.openshift.io/v1alpha1
kind: DRCluster
metadata:
  name: dr1
spec:
  s3ProfileName: minio
  region: east
---
apiVersion: ramendr.openshift.io/v1alpha1
kind: DRCluster
metadata:
  name: dr2
spec:
  s3ProfileName: minio
  region: west
---
apiVersion: ramendr.openshift.io/v1alpha1
kind: DRPolicy
metadata:
  name: ${DR_POLICY_NAME}
spec:
  drClusters:
    - dr1
    - dr2
  schedulingInterval: ${SCHEDULING_INTERVAL}
"

    echo "$dr_resources" | KUBECONFIG="$HUB_KUBECONFIG" kubectl apply -f -

    # Update hub ConfigMap with S3 profile
    log_info "Updating Ramen hub configuration..."
    local hub_config="
apiVersion: v1
kind: ConfigMap
metadata:
  name: ramen-hub-operator-config
  namespace: ${RAMEN_NAMESPACE}
data:
  ramen_manager_config.yaml: |
    apiVersion: ramendr.openshift.io/v1alpha1
    kind: RamenConfig
    ramenControllerType: dr-hub
    maxConcurrentReconciles: 50
    s3StoreProfiles:
      - s3ProfileName: minio
        s3Bucket: ${MINIO_BUCKET}
        s3CompatibleEndpoint: ${minio_endpoint}
        s3Region: minio
        s3SecretRef:
          name: s3-secret
          namespace: ${RAMEN_NAMESPACE}
"

    echo "$hub_config" | KUBECONFIG="$HUB_KUBECONFIG" kubectl apply -f -

    # Restart hub operator to pick up config
    KUBECONFIG="$HUB_KUBECONFIG" kubectl rollout restart deployment -l app=ramen-hub -n "$RAMEN_NAMESPACE" || true

    log_success "Ramen configuration complete"
}

# =============================================================================
# PHASE: CREATE E2E CONFIG
# =============================================================================

create_e2e_config() {
    log_info "=========================================="
    log_info "Phase: Creating E2E Test Configuration"
    log_info "=========================================="

    local config_file="${HOME}/ramen-e2e-config.yaml"

    cat > "$config_file" <<EOF
# Ramen E2E Test Configuration
# Generated by setup-rke2-environment.sh on $(date)

clusters:
  hub:
    kubeconfig: ${HUB_KUBECONFIG}
  c1:
    kubeconfig: ${DR1_KUBECONFIG}
  c2:
    kubeconfig: ${DR2_KUBECONFIG}

distro: rke2
drPolicy: ${DR_POLICY_NAME}
clusterSet: default

pvcSpecs:
  - name: longhorn
    storageClassName: longhorn-ramen
    accessModes: ReadWriteOnce

deployers:
  - name: appset
    type: appset
    description: "ApplicationSet deployer"

tests:
  - workload: deploy
    deployer: appset
    pvcSpec: longhorn
EOF

    log_success "E2E config created: $config_file"
    echo ""
    echo "To run tests:"
    echo "  cd /path/to/ramen/e2e"
    echo "  ./run.sh -config $config_file"
}

# =============================================================================
# PHASE: VERIFY
# =============================================================================

verify_setup() {
    log_info "=========================================="
    log_info "Phase: Verifying Setup"
    log_info "=========================================="

    echo ""
    echo "=== OCM Managed Clusters ==="
    KUBECONFIG="$HUB_KUBECONFIG" kubectl get managedclusters || true

    echo ""
    echo "=== Ramen Hub Operator ==="
    KUBECONFIG="$HUB_KUBECONFIG" kubectl get pods -n "$RAMEN_NAMESPACE" -l app=ramen-hub || true

    echo ""
    echo "=== DR Resources ==="
    KUBECONFIG="$HUB_KUBECONFIG" kubectl get drpolicy,drcluster || true

    echo ""
    echo "=== DR1 Components ==="
    echo "Longhorn:"
    KUBECONFIG="$DR1_KUBECONFIG" kubectl get pods -n longhorn-system --no-headers | head -3 || true
    echo "Velero:"
    KUBECONFIG="$DR1_KUBECONFIG" kubectl get pods -n velero --no-headers || true
    echo "VolSync:"
    KUBECONFIG="$DR1_KUBECONFIG" kubectl get pods -n volsync-system --no-headers || true

    echo ""
    echo "=== DR2 Components ==="
    echo "Longhorn:"
    KUBECONFIG="$DR2_KUBECONFIG" kubectl get pods -n longhorn-system --no-headers | head -3 || true
    echo "Velero:"
    KUBECONFIG="$DR2_KUBECONFIG" kubectl get pods -n velero --no-headers || true
    echo "VolSync:"
    KUBECONFIG="$DR2_KUBECONFIG" kubectl get pods -n volsync-system --no-headers || true

    echo ""
    echo "=== Storage Classes ==="
    KUBECONFIG="$DR1_KUBECONFIG" kubectl get sc longhorn-ramen -o wide || true

    log_success "Verification complete"
}

# =============================================================================
# MAIN
# =============================================================================

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --phase PHASE    Run specific phase only. Available phases:
                   ocm, longhorn, snapshotter, minio, velero, volsync, ramen, config, e2e-config, verify, all
  --verify         Run verification only
  --help           Show this help message

Environment Variables:
  HUB_KUBECONFIG   Path to hub cluster kubeconfig (default: ~/.kube/hub-config)
  DR1_KUBECONFIG   Path to dr1 cluster kubeconfig (default: ~/.kube/dr1-config)
  DR2_KUBECONFIG   Path to dr2 cluster kubeconfig (default: ~/.kube/dr2-config)
  HUB_API_SERVER   Hub API server URL (auto-detected if not set)
  MINIO_ACCESS_KEY MinIO access key (default: minio)
  MINIO_SECRET_KEY MinIO secret key (default: minio123)

Example:
  # Run all phases
  HUB_API_SERVER=https://192.168.1.10:6443 $0

  # Run specific phase
  $0 --phase ocm

  # Verify setup
  $0 --verify
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
            --verify)
                phase="verify"
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
    echo "  Ramen DR Setup for RKE2 + Longhorn"
    echo "=============================================="
    echo ""
    echo "Configuration:"
    echo "  Hub kubeconfig: $HUB_KUBECONFIG"
    echo "  DR1 kubeconfig: $DR1_KUBECONFIG"
    echo "  DR2 kubeconfig: $DR2_KUBECONFIG"
    echo "  Hub API Server: ${HUB_API_SERVER:-auto-detect}"
    echo ""

    check_prerequisites

    case $phase in
        all)
            install_ocm
            configure_longhorn
            install_snapshotter
            install_minio
            install_velero
            install_volsync
            install_ramen
            configure_ramen
            create_e2e_config
            verify_setup
            ;;
        ocm)
            install_ocm
            ;;
        longhorn)
            configure_longhorn
            ;;
        snapshotter)
            install_snapshotter
            ;;
        minio)
            install_minio
            ;;
        velero)
            install_velero
            ;;
        volsync)
            install_volsync
            ;;
        ramen)
            install_ramen
            ;;
        config)
            configure_ramen
            ;;
        e2e-config)
            create_e2e_config
            ;;
        verify)
            verify_setup
            ;;
        *)
            log_error "Unknown phase: $phase"
            usage
            exit 1
            ;;
    esac

    echo ""
    log_success "=========================================="
    log_success "Setup complete!"
    log_success "=========================================="
    echo ""
    echo "Next steps:"
    echo "  1. Review: $0 --verify"
    echo "  2. Run tests: cd ramen/e2e && ./run.sh -config ~/ramen-e2e-config.yaml"
    echo ""
}

main "$@"
