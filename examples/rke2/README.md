# RKE2 Configuration Examples

This directory contains example configurations for deploying Ramen DR on RKE2 clusters.

## Prerequisites

1. **RKE2 Clusters**: At least 3 RKE2 clusters (1 hub, 2 managed)
2. **OCM (Open Cluster Management)**: Installed on all clusters
3. **Longhorn**: Installed on managed clusters for storage
4. **Velero**: Installed on managed clusters for backup
5. **S3-compatible Storage**: MinIO or similar for backup storage

## Configuration Files

| File | Description |
|------|-------------|
| `dr_hub_config.yaml` | RamenConfig for the hub operator |
| `dr_cluster_config.yaml` | RamenConfig for DR cluster operators |
| `drpolicy.yaml` | Sample DRPolicy resource |
| `drcluster.yaml` | Sample DRCluster resources |

## Installation Steps

### 1. Deploy Hub Operator

On the OCM hub cluster:

```bash
# Create ConfigMap with hub configuration
kubectl create configmap ramen-hub-operator-config \
  --from-file=ramen_manager_config.yaml=dr_hub_config.yaml \
  -n ramen-system

# Deploy hub operator
kubectl apply -k config/hub/default/k8s
```

### 2. Deploy DR Cluster Operator

On each managed RKE2 cluster:

```bash
# Create ConfigMap with cluster configuration
kubectl create configmap ramen-dr-cluster-operator-config \
  --from-file=ramen_manager_config.yaml=dr_cluster_config.yaml \
  -n ramen-system

# Deploy DR cluster operator
kubectl apply -k config/dr-cluster/default/k8s
```

### 3. Create DR Resources

On the hub cluster:

```bash
# Create DRCluster resources for each managed cluster
kubectl apply -f drcluster.yaml

# Create DRPolicy
kubectl apply -f drpolicy.yaml
```

## Storage Configuration

### Longhorn StorageClass

Ensure your Longhorn StorageClass has the Ramen label:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn-ramen
  labels:
    ramendr.openshift.io/storageid: "longhorn"
provisioner: driver.longhorn.io
```

### VolumeSnapshotClass

Create a VolumeSnapshotClass for VolSync:

```yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: longhorn-snapshot
  labels:
    ramendr.openshift.io/storageid: "longhorn"
driver: driver.longhorn.io
deletionPolicy: Delete
```

## Verification

Check operator status:

```bash
# On hub
kubectl get pods -n ramen-system -l app=ramen-hub

# On managed clusters
kubectl get pods -n ramen-system -l app=ramen-dr-cluster
```

Check DR resources:

```bash
kubectl get drpolicy,drcluster
```
