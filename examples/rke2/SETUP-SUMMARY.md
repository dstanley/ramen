# Ramen DR Setup on RKE2/Harvester - Summary

This document summarizes the steps to deploy Ramen DR with:
- **Hub cluster**: RKE2 on Proxmox VMs
- **Managed clusters**: Two Harvester clusters (harv, marv)

## Prerequisites

- RKE2 cluster for hub
- Two Harvester clusters for DR
- Container registry accessible from all clusters
- Proxmox VMs with CPU type set to `host` (for x86-64-v2 support)

## 1. Build Ramen Operator Image

### Build for amd64 (from Apple Silicon Mac)

```bash
# Enable Rosetta in Rancher Desktop
rdctl set --virtual-machine.type=vz
rdctl set --virtual-machine.use-rosetta

# Restart Rancher Desktop
rdctl shutdown && sleep 2 && open -a "Rancher Desktop" && sleep 30

# Build for amd64
docker buildx build --platform linux/amd64 -t registry.192.168.7.68.nip.io/ramen-operator:dev --load .
```

### Push to Registry (with self-signed cert)

```bash
# Using skopeo to bypass TLS issues
docker save registry.192.168.7.68.nip.io/ramen-operator:dev -o ramen-operator.tar
skopeo copy --dest-tls-verify=false docker-archive:ramen-operator.tar docker://registry.192.168.7.68.nip.io/ramen-operator:dev
rm ramen-operator.tar
```

## 2. Configure RKE2 Nodes for Insecure Registry

Create script to update all nodes:

```bash
#!/bin/bash
# update-rke2-registry.sh
SSH_USER="${1:-root}"
REGISTRY="registry.192.168.7.68.nip.io"

NODES=(
    "rke2-master1:192.168.7.79:server"
    "rke2-master2:192.168.7.67:server"
    "rke2-master3:192.168.7.80:server"
    "rke2-worker1:192.168.7.68:agent"
    "rke2-worker2:192.168.7.69:agent"
    "rke2-longhorn1:192.168.7.70:agent"
    "rke2-longhorn2:192.168.7.71:agent"
    "rke2-longhorn3:192.168.7.72:agent"
)

REGISTRIES_YAML="mirrors:
  \"${REGISTRY}\":
    endpoint:
      - \"https://${REGISTRY}\"
configs:
  \"${REGISTRY}\":
    tls:
      insecure_skip_verify: true"

for node_entry in "${NODES[@]}"; do
    IFS=':' read -r name ip type <<< "$node_entry"
    echo "=== Configuring $name ($ip) ==="
    ssh "${SSH_USER}@${ip}" "sudo mkdir -p /etc/rancher/rke2 && echo '${REGISTRIES_YAML}' | sudo tee /etc/rancher/rke2/registries.yaml"
    if [ "$type" = "server" ]; then
        ssh "${SSH_USER}@${ip}" "sudo systemctl restart rke2-server"
    else
        ssh "${SSH_USER}@${ip}" "sudo systemctl restart rke2-agent"
    fi
done
```

Run: `./update-rke2-registry.sh root`

## 3. Install OCM Hub

**IMPORTANT**: Use clusteradm **v0.11.2** - newer versions removed the `application-manager` addon which is required for ManagedClusterView support.

```bash
# Download clusteradm v0.11.2 (NOT latest!)
curl -LO "https://github.com/open-cluster-management-io/clusteradm/releases/download/v0.11.2/clusteradm_darwin_arm64.tar.gz"
tar -xzf clusteradm_darwin_arm64.tar.gz
chmod +x clusteradm
mv clusteradm ~/go/bin/  # or another directory in your PATH

# Verify version
clusteradm version
# Should show: client version: v0.11.2

# Initialize hub
clusteradm init --wait

# Verify
kubectl get pods -n open-cluster-management
kubectl get pods -n open-cluster-management-hub
```

## 4. Install OCM CRDs (Required by Ramen)

Ramen requires several OCM CRDs that are bundled in the repo:

```bash
# ManagedClusterView CRD
kubectl apply -f hack/test/view.open-cluster-management.io_managedclusterviews.yaml

# PlacementRule CRD
kubectl apply -f hack/test/apps.open-cluster-management.io_placementrules_crd.yaml
```

## 5. Install OCM Addons for ManagedClusterView Support

ManagedClusterView (MCV) allows the hub to read resources from managed clusters. This requires specific addons.

### 5.1 Install application-manager Hub Addon

```bash
# Must use clusteradm v0.11.2 for this command
clusteradm install hub-addon --names application-manager

# Verify pods are running
kubectl get pods -n open-cluster-management | grep -E "subscription|channel|appsub|placementrule"
```

Expected pods:
- multicluster-operators-subscription
- multicluster-operators-channel
- multicluster-operators-appsub-summary
- multicluster-operators-placementrule

### 5.2 Install work-manager ClusterManagementAddOn

Clone multicloud-operators-foundation and apply the work-manager addon:

```bash
cd /tmp
git clone --depth 1 https://github.com/stolostron/multicloud-operators-foundation.git

# Apply CRDs to hub
kubectl apply -f multicloud-operators-foundation/deploy/foundation/hub/crds/

# Apply RBAC
kubectl apply -f multicloud-operators-foundation/deploy/foundation/hub/rbac/

# Apply ocm-controller (processes MCV on hub)
kubectl apply -f multicloud-operators-foundation/deploy/foundation/hub/ocm-controller/ocm-controller.yaml

# Apply work-manager ClusterManagementAddOn
kubectl apply -f multicloud-operators-foundation/deploy/foundation/hub/ocm-controller/clustermanagementaddon.yaml

# Verify
kubectl get clustermanagementaddon
# Should show: application-manager and work-manager
```

## 6. Deploy Ramen Hub Operator

```bash
make deploy-hub IMG=registry.192.168.7.68.nip.io/ramen-operator:dev PLATFORM=k8s

# Verify
kubectl get pods -n ramen-system
```

## 7. Deploy MinIO for S3 Storage

```bash
kubectl apply -f examples/rke2/minio.yaml

# Wait for pod
kubectl get pods -n minio-system -w

# Create bucket
kubectl -n minio-system run mc-create-bucket --rm -it --restart=Never \
  --image=minio/mc:RELEASE.2023-01-28T20-29-38Z \
  --command -- /bin/sh -c "mc alias set myminio http://minio.minio-system.svc.cluster.local:9000 minioadmin minioadmin && mc mb --ignore-existing myminio/ramen"
```

## 8. Configure Ramen Hub

```bash
# Create S3 secret
kubectl create secret generic s3-secret -n ramen-system \
  --from-literal=AWS_ACCESS_KEY_ID=minioadmin \
  --from-literal=AWS_SECRET_ACCESS_KEY=minioadmin

# Create hub config
kubectl create configmap ramen-hub-operator-config -n ramen-system \
  --from-file=ramen_manager_config.yaml=examples/rke2/dr_hub_config.yaml

# Restart to pick up config
kubectl rollout restart deployment -n ramen-system ramen-hub-operator

# Verify
kubectl logs -n ramen-system deployment/ramen-hub-operator -c manager --tail=20
```

## 9. Join Managed Clusters (Harvester)

### 9.1 Prepare kubeconfigs

Export kubeconfigs from Harvester clusters. Use `insecure-skip-tls-verify: true`:

```yaml
# Example: kubie edit harv (or ~/.kube/harv.yaml)
apiVersion: v1
kind: Config
clusters:
- name: "harv"
  cluster:
    server: "https://192.168.7.51/k8s/clusters/local"
    insecure-skip-tls-verify: true
users:
- name: "harv"
  user:
    token: "kubeconfig-user-xxx:token"
contexts:
- name: "harv"
  context:
    user: "harv"
    cluster: "harv"
current-context: "harv"
```

### 9.2 Join clusters to hub

```bash
# Get join token from hub
clusteradm get token

# Join harv (run with harv kubeconfig context)
kubie ctx harv
clusteradm join --hub-token <token> --hub-apiserver https://192.168.7.79:6443 --cluster-name harv --wait

# Join marv
kubie ctx marv
clusteradm join --hub-token <token> --hub-apiserver https://192.168.7.79:6443 --cluster-name marv --wait

# Accept clusters on hub
kubie ctx <hub>
clusteradm accept --clusters harv,marv

# Approve any pending CSRs (may need to run twice)
kubectl get csr | grep -E "harv|marv" | grep Pending
kubectl certificate approve <pending-csr-names>

# Verify
kubectl get managedclusters
```

Expected output:
```
NAME   HUB ACCEPTED   MANAGED CLUSTER URLS   JOINED   AVAILABLE   AGE
harv   true                                  True     True        10m
marv   true                                  True     True        6m
```

## 10. Configure Harvester Nodes for Insecure Registry

```bash
./examples/rke2/update-harvester-registry.sh rancher
```

Or manually:

```bash
SSH_USER="rancher"
NODES=("harv:192.168.7.250" "marv:192.168.7.25")

for node_entry in "${NODES[@]}"; do
    IFS=':' read -r name ip <<< "$node_entry"
    ssh "${SSH_USER}@${ip}" bash -s <<'EOF'
        sudo mkdir -p /etc/rancher/rke2
        cat << 'YAML' | sudo tee /etc/rancher/rke2/registries.yaml
mirrors:
  "registry.192.168.7.68.nip.io":
    endpoint:
      - "https://registry.192.168.7.68.nip.io"
configs:
  "registry.192.168.7.68.nip.io":
    tls:
      insecure_skip_verify: true
YAML
        sudo systemctl restart rke2-server
EOF
done
```

## 11. Install Required CRDs on Managed Clusters

Ramen requires several CRDs on managed clusters for the DR cluster operator to function.

### 11.1 CSI Addon CRDs

```bash
# Apply to both harv and marv
for cluster in harv marv; do
  echo "=== Applying CRDs to $cluster ==="
  kubie exec $cluster default kubectl apply -f hack/test/replication.storage.openshift.io_volumereplicationclasses.yaml
  kubie exec $cluster default kubectl apply -f hack/test/replication.storage.openshift.io_volumereplications.yaml
  kubie exec $cluster default kubectl apply -f hack/test/replication.storage.openshift.io_volumegroupreplicationclasses.yaml
  kubie exec $cluster default kubectl apply -f hack/test/replication.storage.openshift.io_volumegroupreplicationcontents.yaml
  kubie exec $cluster default kubectl apply -f hack/test/replication.storage.openshift.io_volumegroupreplications.yaml
  kubie exec $cluster default kubectl apply -f hack/test/groupsnapshot.storage.openshift.io_volumegroupsnapshotclasses.yaml
  kubie exec $cluster default kubectl apply -f hack/test/groupsnapshot.storage.openshift.io_volumegroupsnapshotcontents.yaml
  kubie exec $cluster default kubectl apply -f hack/test/groupsnapshot.storage.openshift.io_volumegroupsnapshots.yaml
  kubie exec $cluster default kubectl apply -f hack/test/networkfenceclasses.csiaddons.openshift.io.yaml
  kubie exec $cluster default kubectl apply -f hack/test/csiaddonsnodes.csiaddons.openshift.io.yaml
done
```

### 11.2 ManagedServiceAccount CRD (Required for OCM addons)

```bash
MSA_CRD="https://raw.githubusercontent.com/stolostron/managed-serviceaccount/main/config/crd/bases/authentication.open-cluster-management.io_managedserviceaccounts.yaml"

kubie exec harv default kubectl apply -f "$MSA_CRD"
kubie exec marv default kubectl apply -f "$MSA_CRD"
```

## 12. Deploy DR Cluster Operator on Managed Clusters

```bash
# On harv
kubie ctx harv
make deploy-dr-cluster IMG=registry.192.168.7.68.nip.io/ramen-operator:dev PLATFORM=k8s

# On marv
kubie ctx marv
make deploy-dr-cluster IMG=registry.192.168.7.68.nip.io/ramen-operator:dev PLATFORM=k8s

# Verify pods are running (2/2)
kubie exec harv default kubectl get pods -n ramen-system
kubie exec marv default kubectl get pods -n ramen-system
```

## 13. Install VolSync on Managed Clusters

```bash
# Install via Helm
for cluster in harv marv; do
  echo "=== Installing VolSync on $cluster ==="
  kubie exec $cluster default helm repo add backube https://backube.github.io/helm-charts/
  kubie exec $cluster default helm install volsync backube/volsync -n volsync-system --create-namespace
done

# Verify
kubie exec harv default kubectl get pods -n volsync-system
kubie exec marv default kubectl get pods -n volsync-system
```

## 13a. Configure StorageClass and VolumeSnapshotClass Labels (Critical!)

**This step is required for VolSync async replication to work.**

Each cluster must have a **unique** `ramendr.openshift.io/storageid` label. Same storageID across clusters triggers sync (VolumeReplication) mode instead of async (VolSync).

```bash
# On harv cluster
KUBECONFIG=/path/to/harv_kubeconfig.yaml kubectl label storageclass harvester-longhorn \
  ramendr.openshift.io/storageid=longhorn-harv --overwrite
KUBECONFIG=/path/to/harv_kubeconfig.yaml kubectl label volumesnapshotclass longhorn-snapshot \
  ramendr.openshift.io/storageid=longhorn-harv --overwrite

# On marv cluster
KUBECONFIG=/path/to/marv_kubeconfig.yaml kubectl label storageclass harvester-longhorn \
  ramendr.openshift.io/storageid=longhorn-marv --overwrite
KUBECONFIG=/path/to/marv_kubeconfig.yaml kubectl label volumesnapshotclass longhorn-snapshot \
  ramendr.openshift.io/storageid=longhorn-marv --overwrite
```

Also set `longhorn-snapshot` as the default VolumeSnapshotClass (it uses local snapshots, unlike `longhorn` which requires a backup target):

```bash
for cluster in harv marv; do
  kubie exec $cluster default kubectl annotate volumesnapshotclass longhorn-snapshot \
    snapshot.storage.kubernetes.io/is-default-class=true --overwrite
done
```

## 13b. Install Submariner (Optional but Recommended)

Submariner provides secure cross-cluster networking. Without it, VolSync uses LoadBalancer services which may not work in all environments.

### Install subctl CLI

```bash
# Download latest subctl
curl -Ls https://get.submariner.io | VERSION=v0.22.1 bash

# Or install specific version
curl -LO https://github.com/submariner-io/subctl/releases/download/v0.22.1/subctl-v0.22.1-darwin-arm64.tar.gz
tar -xzf subctl-v0.22.1-darwin-arm64.tar.gz
mv subctl-v0.22.1/subctl /usr/local/bin/
```

**Important:** Use Submariner v0.22.1 or later for Kubernetes 1.34+ compatibility.

### Deploy Submariner Broker

```bash
# Deploy broker on hub cluster (or one of the managed clusters)
KUBECONFIG=/path/to/hub_kubeconfig.yaml subctl deploy-broker
```

This creates a `broker-info.subm` file containing connection details.

### Join Clusters to Submariner

```bash
# Join harv cluster (specify CIDRs to avoid auto-discovery issues)
KUBECONFIG=/path/to/harv_kubeconfig.yaml subctl join broker-info.subm \
  --clusterid harv \
  --clustercidr 10.52.0.0/16 \
  --servicecidr 10.53.0.0/16

# Join marv cluster
KUBECONFIG=/path/to/marv_kubeconfig.yaml subctl join broker-info.subm \
  --clusterid marv \
  --clustercidr 10.48.0.0/16 \
  --servicecidr 10.49.0.0/16
```

**Note:** Adjust CIDRs to match your cluster's actual pod and service CIDRs. You can find them with:
```bash
kubectl cluster-info dump | grep -m 1 cluster-cidr
kubectl cluster-info dump | grep -m 1 service-cluster-ip-range
```

### Verify Submariner Connectivity

```bash
# Check connection status
KUBECONFIG=/path/to/harv_kubeconfig.yaml subctl show connections

# Test cross-cluster connectivity
KUBECONFIG=/path/to/harv_kubeconfig.yaml subctl diagnose all
```

Expected output shows connected gateways with low latency (~4ms for local network).

## 14. Create ClusterClaim Resources on Managed Clusters

Each managed cluster needs a ClusterClaim to identify itself:

```bash
# On harv
kubie exec harv default kubectl apply -f examples/rke2/clusterclaim-harv.yaml

# On marv
kubie exec marv default kubectl apply -f examples/rke2/clusterclaim-marv.yaml

# Verify
kubie exec harv default kubectl get clusterclaim
kubie exec marv default kubectl get clusterclaim
```

## 15. Enable OCM Addons on Managed Clusters

Back on the hub, enable the addons for the managed clusters:

```bash
# Enable application-manager addon
clusteradm addon enable --names application-manager --clusters harv,marv

# Wait for pods to start on managed clusters
sleep 30

# Verify on managed clusters
kubie exec harv default kubectl get pods -n open-cluster-management-agent-addon
kubie exec marv default kubectl get pods -n open-cluster-management-agent-addon
```

Expected pods on each managed cluster:
- application-manager
- klusterlet-addon-workmgr (this processes ManagedClusterView!)

## 16. Create DRCluster and DRPolicy Resources

On the hub cluster:

```bash
kubectl apply -f examples/rke2/drcluster.yaml
kubectl apply -f examples/rke2/drpolicy.yaml

# Verify validation
kubectl get drcluster -o jsonpath='{range .items[*]}{.metadata.name}: {.status.conditions[?(@.type=="Validated")].status}{"\n"}{end}'
kubectl get drpolicy -o jsonpath='{.items[0].status.conditions[?(@.type=="Validated")].status}'
```

Expected output:
```
harv: True
marv: True
True
```

## Verification Checklist

```bash
# Hub cluster
kubectl get managedclusters                    # Both should be Available=True
kubectl get clustermanagementaddon             # application-manager, work-manager
kubectl get drcluster                          # Both should exist
kubectl get drpolicy                           # Should exist
kubectl get managedclusterview -A              # MCVs should have Processing=True

# Check DRCluster validation
kubectl get drcluster harv -o jsonpath='{.status.conditions[?(@.type=="Validated")].message}'
# Should show: "Validated the cluster"

# Managed clusters (harv/marv)
kubie exec harv default kubectl get pods -n ramen-system             # 2/2 Running
kubie exec harv default kubectl get pods -n open-cluster-management-agent-addon  # application-manager, klusterlet-addon-workmgr
kubie exec harv default kubectl get drclusterconfig                   # Should exist with status
kubie exec harv default kubectl get clusterclaim                      # id.k8s.io
```

## Troubleshooting

### ManagedClusterView Not Working

If DRClusters show "missing ManagedClusterView conditions":

1. Verify `klusterlet-addon-workmgr` is running on managed clusters
2. Check ClusterManagementAddOn/work-manager exists on hub
3. Check ManagedClusterAddOn/work-manager exists in managed cluster namespaces

```bash
# On hub
kubectl get clustermanagementaddon work-manager
kubectl get managedclusteraddon -A | grep work-manager

# On managed cluster
kubie exec harv default kubectl get pods -n open-cluster-management-agent-addon | grep workmgr
```

### DR Cluster Operator CrashLoopBackOff

If the dr-cluster operator crashes with CRD errors, ensure all CSI addon CRDs are installed (see step 11.1).

### Proxmox VM CPU Issues

If pods fail with "CPU does not support x86-64-v2":
1. Proxmox UI -> VM -> Hardware -> Processors -> Edit -> Type: `host`
2. Reboot VM

### RKE2 Node Network Issues

If nodes have no default route after reboot:
```bash
ssh user@node "sudo ip route add default via 192.168.7.1"
ssh user@node "echo 'default 192.168.7.1 - -' | sudo tee /etc/sysconfig/network/routes"
```

### DNS Issues on Nodes

```bash
ssh user@node "echo 'nameserver 8.8.8.8' | sudo tee /etc/resolv.conf"
```

### S3 Bucket Not Found

If DRCluster shows "NoSuchBucket" error, recreate the MinIO bucket:

```bash
kubectl -n minio-system run mc-create-bucket --rm -it --restart=Never \
  --image=minio/mc:RELEASE.2023-01-28T20-29-38Z \
  --command -- /bin/sh -c "mc alias set myminio http://minio.minio-system.svc.cluster.local:9000 minioadmin minioadmin && mc mb --ignore-existing myminio/ramen"
```

### VolSync "setgid failed" Error

If ReplicationSource logs show `@ERROR: setgid failed`, the rsync mover needs security context configuration.

Add `moverSecurityContext` to the DRPC:

```bash
kubectl patch drpc -n <namespace> <drpc-name> --type=merge -p '
{
  "spec": {
    "volSyncSpec": {
      "moverConfig": [{
        "pvcName": "<pvc-name>",
        "pvcNamespace": "<namespace>",
        "moverSecurityContext": {
          "runAsUser": 65534,
          "runAsGroup": 65534,
          "fsGroup": 65534
        }
      }]
    }
  }
}'
```

Then delete and let Ramen recreate the ReplicationSource/ReplicationDestination:

```bash
kubectl delete replicationsource -n <namespace> <pvc-name>
kubectl delete replicationdestination -n <namespace> <pvc-name>  # on secondary cluster
kubectl annotate vrg -n <namespace> <vrg-name> reconcile="$(date +%s)" --overwrite
```

### VolSync "DNS resolution failed" (clusterset.local)

If the ReplicationSource can't resolve `*.clusterset.local`:

1. Verify Submariner is installed and connected:
   ```bash
   subctl show connections
   ```

2. Verify the ServiceExport exists on the destination cluster:
   ```bash
   kubectl get serviceexport -n <namespace>
   ```

3. Test DNS resolution from the source cluster:
   ```bash
   kubectl run -it --rm debug --image=busybox --restart=Never -- \
     nslookup volsync-rsync-tls-dst-<pvc-name>.<namespace>.svc.clusterset.local
   ```

### VolSync Uses Wrong VolumeSnapshotClass

If VolumeSnapshots use `longhorn` instead of `longhorn-snapshot` and fail with "backup target not available":

1. Ensure StorageClass has the correct `storageid` label matching the VolumeSnapshotClass
2. Ensure `longhorn-snapshot` is set as default:
   ```bash
   kubectl annotate volumesnapshotclass longhorn-snapshot \
     snapshot.storage.kubernetes.io/is-default-class=true
   ```
3. Delete and recreate the ReplicationSource

### DRPolicy Shows Sync Instead of Async Peer Classes

If `kubectl get drpolicy -o yaml` shows `sync.peerClasses` populated but `async.peerClasses` empty:

The StorageClasses on both clusters have the **same** `storageid` label. This triggers sync detection.

Fix: Ensure each cluster has a unique storageID:
```bash
# On cluster 1
kubectl label storageclass harvester-longhorn ramendr.openshift.io/storageid=longhorn-cluster1 --overwrite

# On cluster 2
kubectl label storageclass harvester-longhorn ramendr.openshift.io/storageid=longhorn-cluster2 --overwrite
```

Then trigger DRPolicy reconciliation:
```bash
kubectl annotate drpolicy dr-policy reconcile="$(date +%s)" --overwrite
```

### Submariner Network Discovery Fails (K8s 1.34+)

If `subctl join` fails with "could not determine the service IP range":

This is a known issue with Submariner versions prior to 0.22.x on Kubernetes 1.34+.

**Solution 1:** Upgrade to Submariner v0.22.1+

**Solution 2:** Explicitly provide CIDRs during join:
```bash
subctl join broker-info.subm \
  --clusterid <name> \
  --clustercidr <pod-cidr> \
  --servicecidr <service-cidr>
```

### VRG Not Finding PVCs After Failover (created-by-ramen label)

After failover, the VRG on the new primary cluster may show "No PVCs are protected using Volsync scheme" even though PVCs exist.

**Symptom:** VRG controller logs show:
```
Found 0 PVCs using label selector app=rto-rpo-test,app.kubernetes.io/created-by notin (volsync),ramendr.openshift.io/created-by-ramen notin (true)
```

**Cause:** The restored PVC has the label `ramendr.openshift.io/created-by-ramen: "true"` which is excluded from the VRG's PVC selector.

**Fix:** Remove the label from the PVC:
```bash
kubectl label pvc <pvc-name> -n <namespace> ramendr.openshift.io/created-by-ramen-
```

The VRG will then find the PVC and create a ReplicationSource for reverse replication.

### Namespace Stuck Terminating After Failover

After failover, the old namespace on the source cluster may be stuck in Terminating state.

**Symptom:**
```
Some content in the namespace has finalizers remaining:
volumereplicationgroups.ramendr.openshift.io/pvc-volsync-protection in 1 resource instances
```

**Cause:** A PVC has a VRG finalizer that wasn't cleaned up properly during failover.

**Fix:** Remove the finalizer from the stuck PVC:
```bash
kubectl patch pvc <pvc-name> -n <namespace> -p '{"metadata":{"finalizers":null}}' --type=merge
```

Then recreate the namespace if needed for the secondary VRG.

### VolSync PSK Secret Missing After Namespace Recreation

After a namespace is deleted and recreated (e.g., due to stuck terminating state), the VolSync PSK secret may be missing.

**Symptom:** VRG controller logs show:
```
ERROR Failed to reconcile VolSync Replication Destination "error": "psk secret: <drpc-name>-vs-secret is not found"
```

**Cause:** The PSK secret was deleted with the namespace and wasn't recreated by DRPC.

**Fix:** Copy the PSK secret from the peer cluster:
```bash
# Get secret from primary cluster
kubectl get secret <drpc-name>-vs-secret -n <namespace> -o json | \
  jq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.ownerReferences, .metadata.managedFields)' \
  > /tmp/vs-secret.json

# Apply to secondary cluster (use appropriate kubeconfig)
kubectl apply -f /tmp/vs-secret.json
```

Then trigger VRG reconciliation:
```bash
kubectl annotate vrg <vrg-name> -n <namespace> reconcile="$(date +%s)" --overwrite
```

### ManifestWork Stuck with Stale Error

After fixing namespace issues, ManifestWork may still show old errors.

**Symptom:** ManifestWork shows "namespace is being terminated" error even after namespace is recreated.

**Fix:** Delete and let DRPC recreate the ManifestWork:
```bash
kubectl delete manifestwork <manifestwork-name> -n <cluster-namespace>
```

The DRPC controller will recreate it within a few seconds.

## Architecture Summary

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           Hub Cluster (RKE2)                            │
├─────────────────────────────────────────────────────────────────────────┤
│  open-cluster-management:                                               │
│    - cluster-manager                                                    │
│    - multicluster-operators-subscription  (processes subscriptions)     │
│    - multicluster-operators-channel                                     │
│    - ocm-controller  (from stolostron/multicloud-operators-foundation)  │
│                                                                         │
│  open-cluster-management-hub:                                           │
│    - cluster-manager-registration-controller                            │
│    - cluster-manager-placement-controller                               │
│    - cluster-manager-work-webhook                                       │
│                                                                         │
│  ramen-system:                                                          │
│    - ramen-hub-operator                                                 │
│                                                                         │
│  minio-system:                                                          │
│    - minio (S3 storage for DR metadata)                                 │
└─────────────────────────────────────────────────────────────────────────┘
           │                                        │
           │  ManifestWork (push)                   │  ManagedClusterView (pull)
           │  DRClusterConfig                       │  DRClusterConfig status
           ▼                                        ▼
┌──────────────────────────────┐    ┌──────────────────────────────┐
│   Managed Cluster: harv      │    │   Managed Cluster: marv      │
├──────────────────────────────┤    ├──────────────────────────────┤
│  open-cluster-management-    │    │  open-cluster-management-    │
│  agent-addon:                │    │  agent-addon:                │
│    - application-manager     │    │    - application-manager     │
│    - klusterlet-addon-workmgr│    │    - klusterlet-addon-workmgr│
│                              │    │                              │
│  ramen-system:               │    │  ramen-system:               │
│    - ramen-dr-cluster-operator│   │    - ramen-dr-cluster-operator│
│                              │    │                              │
│  volsync-system:             │    │  volsync-system:             │
│    - volsync                 │    │    - volsync                 │
│                              │    │                              │
│  longhorn-system:            │    │  longhorn-system:            │
│    - longhorn (CSI storage)  │    │    - longhorn (CSI storage)  │
└──────────────────────────────┘    └──────────────────────────────┘
```

## Key Components for MCV

The **ManagedClusterView** mechanism allows the hub to read resources from managed clusters:

1. **Hub side**: `ClusterManagementAddOn/work-manager` tells OCM to deploy the work-manager agent
2. **Managed cluster side**: `klusterlet-addon-workmgr` watches for MCV resources and fetches data

Without this, the hub operator cannot read DRClusterConfig status (storage classes, CIDRs, etc.) from managed clusters.

## Failover and Failback Procedures

### Triggering a Failover

To failover from the current primary cluster to the secondary:

```bash
# On hub cluster
kubectl patch drpc <drpc-name> -n <namespace> --type=merge \
  -p '{"spec":{"action":"Failover","failoverCluster":"<target-cluster>"}}'
```

**Monitor progress:**
```bash
kubectl get drpc -n <namespace> -o jsonpath='Phase: {.items[0].status.phase}, Progression: {.items[0].status.progression}'
```

**Expected progression:**
1. `FailingOver` / `WaitingForResourceRestore`
2. `FailedOver` / `Cleaning Up`
3. `FailedOver` / `SettingUpVolSyncDest`
4. `FailedOver` / `Completed` (Protected: True)

### Triggering a Failback (Relocate)

To failback to the original primary cluster after data has been synced:

```bash
# On hub cluster
kubectl patch drpc <drpc-name> -n <namespace> --type=merge \
  -p '{"spec":{"action":"Relocate","preferredCluster":"<original-primary>"}}'
```

**Note:** Relocate requires that VolSync has successfully synced data back to the target cluster.

### Verifying Protection Status

```bash
# Check DRPC status
kubectl get drpc -n <namespace> -o jsonpath='{range .items[0].status.conditions[*]}{.type}: {.status} - {.message}{"\n"}{end}'

# Check VolSync replication
kubectl get replicationsource -n <namespace> -o wide   # On primary
kubectl get replicationdestination -n <namespace> -o wide  # On secondary

# Check VRG status on managed cluster
kubectl get vrg -n <namespace> -o jsonpath='{range .items[0].status.conditions[*]}{.type}: {.status}{"\n"}{end}'
```

### Post-Failover Checklist

After a failover completes, verify:

1. **App running on target cluster:**
   ```bash
   kubectl get pods -n <namespace> -l <app-label>
   ```

2. **Data accessible:**
   ```bash
   kubectl exec -n <namespace> <pod> -- ls -la /data/
   ```

3. **VolSync reverse replication working:**
   ```bash
   kubectl get replicationsource -n <namespace>  # Should show LAST SYNC time
   ```

4. **DRPC Protected: True:**
   ```bash
   kubectl get drpc -n <namespace> -o jsonpath='{.items[0].status.conditions[?(@.type=="Protected")].status}'
   ```

## Application ManifestWork Management

When using manual ManifestWorks (not OCM Subscriptions), you must manage the application lifecycle during DR operations:

### Important: Namespace Ownership

**CRITICAL**: If your app ManifestWork includes the Namespace resource, deleting the ManifestWork will delete the namespace and ALL its contents (including VRG, PVCs, and data).

**Best Practice**: Use separate ManifestWorks:
1. **Namespace ManifestWork** (managed by Ramen's DRPC) - created automatically
2. **App ManifestWork** (managed by you) - should NOT include namespace

Example app ManifestWork structure:
```yaml
apiVersion: work.open-cluster-management.io/v1
kind: ManifestWork
metadata:
  name: myapp-app
  namespace: <managed-cluster>  # harv or marv
spec:
  workload:
    manifests:
    - apiVersion: v1
      kind: ConfigMap  # NOT Namespace
      metadata:
        name: myapp-config
        namespace: myapp-ns
    - apiVersion: apps/v1
      kind: Deployment
      ...
```

### Relocate (Failback) Process

During a Relocate operation, you must:

1. **Remove app from source cluster FIRST** (before final sync):
   ```bash
   # Delete app ManifestWork from source cluster namespace on hub
   kubectl delete manifestwork myapp-app -n <source-cluster>
   ```

2. **Wait for final sync to complete** - DRPC shows progression `RunningFinalSync` → `EnsuringVolumesAreSecondary`

3. **Apply app to target cluster AFTER relocate completes**:
   ```bash
   # Create app ManifestWork in target cluster namespace on hub
   kubectl apply -f myapp-manifestwork.yaml -n <target-cluster>
   ```

### Final Sync Requirements

For final sync during Relocate to work:
- PVC must be **unmounted** (no pods using it)
- ReplicationSource must be able to run a sync job
- PSK secret must exist on both clusters

If you accidentally delete the namespace on the source cluster before final sync completes:
- The final sync cannot run
- Data is restored from the **last successful sync point**
- Any writes after the last sync will be lost

### Relocate Stuck at RunningFinalSync

If Relocate is stuck at `RunningFinalSync`:

1. **Check if PVC is in use:**
   ```bash
   kubectl get pods -n <namespace> --context <source-cluster>
   ```

2. **If app is still running, remove it:**
   ```bash
   kubectl delete manifestwork <app>-app -n <source-cluster> --context hub
   ```

3. **If namespace was deleted, recreate it:**
   ```bash
   kubectl create ns <namespace> --context <source-cluster>
   # Then trigger ManifestWork reconciliation
   kubectl annotate manifestwork <drpc>-vrg-mw -n <source-cluster> reconcile=$(date +%s) --overwrite --context hub
   ```

4. **Force final sync completion (data loss scenario):**
   ```bash
   # If source data is already lost, patch VRG to indicate sync complete
   kubectl patch vrg <drpc-name> -n <namespace> --context <source-cluster> \
     --type=merge -p '{"spec":{"runFinalSync":true},"status":{"finalSyncComplete":true}}'
   ```

## Known Issues and Bugs

### VRG PVC Finalizer Not Removed During Primary Promotion (Ramen Bug)

**Issue:** During Relocate, when the VRG promotes a cluster to Primary and finds a PVC with wrong datasource (from a previous cycle), it deletes the PVC. However, the PVC has a VRG finalizer (`volumereplicationgroups.ramendr.openshift.io/pvc-volsync-protection`) that blocks deletion.

**Root Cause:** In `vrg_volsync.go:826-847`, the `isPVCDeletedForUnprotection` function returns `false` when:
- VRG ReplicationState is not Primary, OR
- PrepareForFinalSync is true, OR
- RunFinalSync is true

During Primary promotion, the VRG is in a transitional state, so the finalizer removal logic is skipped. The PVC gets stuck in `Terminating` state.

**Workaround:** Manually remove the finalizer:
```bash
kubectl patch pvc <pvc-name> -n <namespace> -p '{"metadata":{"finalizers":null}}' --type=merge
```

**Suggested Fix:** The `ensurePVCFromSnapshot` function in `vshandler.go:2128` should remove the finalizer before calling `Delete` on the PVC with incorrect datasource.

### Application Lifecycle Controller Gap

**Issue:** During Relocate operations, the application must be quiesced (stopped) on the source cluster BEFORE VRG can run the final sync. However:

1. PlacementDecision only changes AFTER final sync completes
2. If you only watch PlacementDecision, you can't know to remove the app early
3. This creates a deadlock: final sync needs PVC deleted, but app is using PVC

**Root Cause:** In a full ACM/OCM setup with Subscriptions, the OCM Application Lifecycle controller would handle this. With manual ManifestWorks, there's no mechanism to detect "Relocate initiated" vs "Relocate completed".

**Workaround:** The app controller must watch BOTH:
1. **DRPC status.phase** (intent) - to detect `Relocating` phase and quiesce app early
2. **PlacementDecision** (state) - to deploy app when placement changes

See the "DRPC-Aware App Controller" section below for implementation.

## DRPC-Aware App Controller

For testing RTO/RPO with manual ManifestWorks, use a controller that watches both DRPC status and PlacementDecision:

```bash
#!/bin/bash
# /tmp/rto-rpo-app-controller.sh
# DRPC-aware app placement controller

NAMESPACE="ramen-test"
PLACEMENT="rto-rpo-test-placement"
DRPC_NAME="rto-rpo-test-drpc"
HUB_CONTEXT="rke2"
LAST_CLUSTER=""
RELOCATE_QUIESCED=""

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1" | tee -a /tmp/app-controller.log
}

deploy_app() {
    local cluster=$1
    log "=== DEPLOY APP TO $cluster ==="

    # Wait for PVC and remove created-by-ramen label
    for i in {1..15}; do
        if kubie exec $cluster $NAMESPACE -- kubectl get pvc rto-rpo-data -n $NAMESPACE &>/dev/null; then
            kubie exec $cluster $NAMESPACE -- kubectl label pvc rto-rpo-data -n $NAMESPACE ramendr.openshift.io/created-by-ramen- --overwrite 2>/dev/null || true
            break
        fi
        sleep 2
    done

    # Apply ManifestWork here (deployment + configmap)
    log "App ManifestWork applied to $cluster"
}

remove_app() {
    local cluster=$1
    log "=== REMOVE APP FROM $cluster ==="
    kubie exec $HUB_CONTEXT $NAMESPACE -- kubectl delete manifestwork rto-rpo-test-app -n $cluster --ignore-not-found
}

log "=== App Controller Started ==="

while true; do
    # 1. MEDIATION: Detect Relocate and quiesce app early
    DRPC_PHASE=$(kubie exec $HUB_CONTEXT $NAMESPACE -- kubectl get drpc $DRPC_NAME -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null)

    if [[ "$DRPC_PHASE" == "Relocating" && -n "$LAST_CLUSTER" && "$RELOCATE_QUIESCED" != "$LAST_CLUSTER" ]]; then
        log "*** DRPC RELOCATING: Quiescing app on $LAST_CLUSTER for Final Sync ***"
        remove_app "$LAST_CLUSTER"
        RELOCATE_QUIESCED="$LAST_CLUSTER"
    fi

    # Reset quiesce flag when not relocating
    [[ "$DRPC_PHASE" != "Relocating" && "$DRPC_PHASE" != "Initiating" ]] && RELOCATE_QUIESCED=""

    # 2. PLACEMENT: Deploy app when placement changes
    CURRENT_CLUSTER=$(kubie exec $HUB_CONTEXT $NAMESPACE -- kubectl get placementdecision -n $NAMESPACE -l cluster.open-cluster-management.io/placement=$PLACEMENT -o jsonpath='{.items[0].status.decisions[0].clusterName}' 2>/dev/null)

    if [[ -n "$CURRENT_CLUSTER" && "$CURRENT_CLUSTER" != "$LAST_CLUSTER" ]]; then
        log "*** PLACEMENT CHANGED: $LAST_CLUSTER -> $CURRENT_CLUSTER ***"
        [[ -n "$LAST_CLUSTER" && "$RELOCATE_QUIESCED" != "$LAST_CLUSTER" ]] && remove_app "$LAST_CLUSTER"
        deploy_app "$CURRENT_CLUSTER"
        LAST_CLUSTER="$CURRENT_CLUSTER"
        RELOCATE_QUIESCED=""
    fi

    sleep 2
done
```

**Key insight:** By watching DRPC phase `Relocating`, the controller can remove the app BEFORE PlacementDecision changes, allowing VRG to delete the PVC and run final sync.

## RTO/RPO Test Results

Test environment: RKE2 hub + 2 Harvester clusters, VolSync rsync-tls over Submariner

### Failover (harv → marv)
- **RTO**: ~52 seconds (from DRPC Failover trigger to app running on marv)
- **RPO**: ~6.5 minutes (data loss window based on VolSync sync interval)

### Failback/Relocate (marv → harv)
- **RTO**: Higher due to final sync requirement
- **RPO**: Minimal (final sync captures latest writes)

**Note:** RPO depends on VolSync schedulingInterval configured in DRPolicy (default: 5m). RTO depends on PVC restore time, app startup time, and whether app controller detects Relocate phase early.


