<!--
SPDX-FileCopyrightText: The RamenDR authors
SPDX-License-Identifier: Apache-2.0
-->

# RKE2 Deployment Guide

This guide describes how to deploy Ramen disaster recovery on RKE2 clusters
with Longhorn storage.

## Overview

RKE2 (Rancher Kubernetes Engine 2) is a fully conformant Kubernetes distribution
that works seamlessly with Ramen. This guide covers the specific steps needed
to set up Ramen DR on RKE2 clusters using Longhorn as the storage backend.

## Prerequisites

### 1. RKE2 Clusters

You need at least three RKE2 clusters:

- **1 Hub cluster** - Runs OCM hub and Ramen hub operator
- **2 Managed clusters** - Run workloads with DR protection

**RKE2 Requirements:**

- RKE2 v1.28 or later
- Minimum 4 CPUs, 8GB RAM per managed cluster node
- Minimum 2 CPUs, 6GB RAM per hub cluster node
- 50GB+ available disk space for Longhorn storage

### 2. Network Connectivity

All clusters must be able to communicate:

- Hub to managed clusters (OCM communication)
- Between managed clusters (for VolSync replication)
- All clusters to S3 storage endpoint

### 3. S3-Compatible Object Storage

Ramen requires S3 storage for backup data:

- MinIO, AWS S3, or any S3-compatible storage
- Accessible from all clusters
- Pre-created bucket for Ramen data

## Installation Steps

### Step 1: Install Open Cluster Management (OCM)

OCM provides the multi-cluster management foundation for Ramen.

#### Install clusteradm CLI

```bash
curl -L https://raw.githubusercontent.com/open-cluster-management-io/clusteradm/main/install.sh | bash
```

#### Initialize OCM Hub

On the hub cluster:

```bash
# Initialize the hub
clusteradm init --wait

# Get the join command for managed clusters
clusteradm get token
```

#### Join Managed Clusters

On each managed cluster, run the join command from the hub:

```bash
clusteradm join \
  --hub-token <token-from-hub> \
  --hub-apiserver <hub-api-server-url> \
  --cluster-name <cluster-name> \
  --wait
```

#### Accept Managed Clusters

On the hub cluster:

```bash
clusteradm accept --clusters <cluster1-name>,<cluster2-name>
```

#### Verify OCM Setup

```bash
kubectl get managedclusters
```

Expected output:

```
NAME        HUB ACCEPTED   MANAGED CLUSTER URLS   JOINED   AVAILABLE   AGE
cluster1    true                                   True     True        5m
cluster2    true                                   True     True        5m
```

### Step 2: Install Longhorn on Managed Clusters

Install Longhorn on each managed cluster for persistent storage.

#### Prerequisites for Longhorn

```bash
# Install open-iscsi (required for Longhorn)
# On RHEL/CentOS:
sudo yum install -y iscsi-initiator-utils

# On Ubuntu/Debian:
sudo apt-get install -y open-iscsi

# Enable and start iscsid
sudo systemctl enable iscsid
sudo systemctl start iscsid
```

#### Install Longhorn

```bash
# Apply Longhorn manifests
kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/v1.7.2/deploy/longhorn.yaml

# Wait for Longhorn to be ready
kubectl -n longhorn-system rollout status deploy/longhorn-manager
kubectl -n longhorn-system rollout status deploy/longhorn-driver-deployer
```

#### Create Ramen-Compatible StorageClass

```yaml
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
```

#### Create VolumeSnapshotClass

```yaml
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
```

### Step 3: Install External Snapshotter

Install the Kubernetes external-snapshotter on each managed cluster:

```bash
# Install CRDs
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/release-8.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/release-8.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/release-8.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml

# Install controller
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/release-8.0/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/release-8.0/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml
```

### Step 4: Install VolSync

VolSync provides asynchronous replication for Longhorn volumes.

On each managed cluster:

```bash
# Install VolSync operator
kubectl apply -f https://raw.githubusercontent.com/backube/volsync/release-0.10/config/crd/bases/volsync.backube_replicationdestinations.yaml
kubectl apply -f https://raw.githubusercontent.com/backube/volsync/release-0.10/config/crd/bases/volsync.backube_replicationsources.yaml

# Deploy VolSync controller
kubectl apply -f https://raw.githubusercontent.com/backube/volsync/release-0.10/deploy/manifests/volsync.yaml
```

### Step 5: Install Velero

Velero provides backup/restore capabilities for Kubernetes resources.

On each managed cluster:

```bash
# Install Velero with S3 backend
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.10.0 \
  --bucket <your-bucket-name> \
  --secret-file ./credentials-velero \
  --backup-location-config region=<region>,s3ForcePathStyle=true,s3Url=<s3-endpoint> \
  --use-volume-snapshots=false
```

### Step 6: Install OLM (Optional)

If using OLM for operator management:

```bash
curl -sL https://github.com/operator-framework/operator-lifecycle-manager/releases/download/v0.28.0/install.sh | bash -s v0.28.0
```

### Step 7: Install Ramen Operators

Follow the standard [Ramen installation guide](install.md) using the `k8s`
platform configuration:

```bash
# On hub cluster
kubectl apply -k "https://github.com/RamenDR/ramen/config/olm-install/hub?ref=main"

# On each managed cluster
kubectl apply -k "https://github.com/RamenDR/ramen/config/olm-install/base?ref=main"
```

### Step 8: Configure Ramen

Create RamenConfig, DRPolicy, and DRCluster resources.

See [examples/rke2/](../examples/rke2/) for sample configurations.

## Configuration

### Hub Operator Configuration

Create the hub operator ConfigMap with S3 profile:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: ramen-hub-operator-config
  namespace: ramen-system
data:
  ramen_manager_config.yaml: |
    apiVersion: ramendr.openshift.io/v1alpha1
    kind: RamenConfig
    ramenControllerType: "dr-hub"
    s3StoreProfiles:
      - s3ProfileName: "s3-profile"
        s3Bucket: "ramen-bucket"
        s3CompatibleEndpoint: "http://minio.minio-system.svc:9000"
        s3Region: "us-east-1"
        s3SecretRef:
          name: "s3-secret"
          namespace: "ramen-system"
```

### DR Cluster Operator Configuration

Create the DR cluster operator ConfigMap on each managed cluster:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: ramen-dr-cluster-operator-config
  namespace: ramen-system
data:
  ramen_manager_config.yaml: |
    apiVersion: ramendr.openshift.io/v1alpha1
    kind: RamenConfig
    ramenControllerType: "dr-cluster"
    volSync:
      destinationCopyMethod: "Snapshot"
    kubeObjectProtection:
      veleroNamespaceName: "velero"
    s3StoreProfiles:
      - s3ProfileName: "s3-profile"
        s3Bucket: "ramen-bucket"
        s3CompatibleEndpoint: "http://minio.minio-system.svc:9000"
        s3Region: "us-east-1"
        s3SecretRef:
          name: "s3-secret"
          namespace: "ramen-system"
```

### Create S3 Secret

Create the S3 credentials secret on all clusters:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: s3-secret
  namespace: ramen-system
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: <your-access-key>
  AWS_SECRET_ACCESS_KEY: <your-secret-key>
```

### Create DRCluster Resources

On the hub cluster:

```yaml
apiVersion: ramendr.openshift.io/v1alpha1
kind: DRCluster
metadata:
  name: cluster1
spec:
  s3ProfileName: "s3-profile"
  region: "east"
---
apiVersion: ramendr.openshift.io/v1alpha1
kind: DRCluster
metadata:
  name: cluster2
spec:
  s3ProfileName: "s3-profile"
  region: "west"
```

### Create DRPolicy

```yaml
apiVersion: ramendr.openshift.io/v1alpha1
kind: DRPolicy
metadata:
  name: dr-policy
spec:
  drClusters:
    - cluster1
    - cluster2
  schedulingInterval: "5m"
```

## Verification

### Check Ramen Operators

```bash
# Hub operator
kubectl get pods -n ramen-system -l app=ramen-hub

# DR cluster operators (on each managed cluster)
kubectl get pods -n ramen-system -l app=ramen-dr-cluster
```

### Check DR Resources

```bash
kubectl get drpolicy,drcluster
```

### Check Storage Configuration

```bash
# Verify StorageClass has Ramen label
kubectl get sc longhorn-ramen -o yaml | grep storageid

# Verify VolumeSnapshotClass
kubectl get volumesnapshotclass longhorn-snapshot -o yaml
```

## Testing DR Operations

### Deploy a Test Workload

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
  namespace: test-app
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn-ramen
  resources:
    requests:
      storage: 1Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-app
  namespace: test-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test-app
  template:
    metadata:
      labels:
        app: test-app
    spec:
      containers:
        - name: busybox
          image: busybox
          command: ["sh", "-c", "while true; do date >> /data/log.txt; sleep 10; done"]
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: test-pvc
```

### Protect the Workload

Create a DRPlacementControl to enable DR protection:

```yaml
apiVersion: ramendr.openshift.io/v1alpha1
kind: DRPlacementControl
metadata:
  name: test-app-drpc
  namespace: test-app
spec:
  drPolicyRef:
    name: dr-policy
  placementRef:
    name: test-app-placement
  pvcSelector:
    matchLabels:
      app: test-app
  preferredCluster: cluster1
```

## Troubleshooting

### Longhorn Issues

```bash
# Check Longhorn manager logs
kubectl -n longhorn-system logs -l app=longhorn-manager

# Verify Longhorn volumes
kubectl get volumes.longhorn.io -n longhorn-system
```

### VolSync Issues

```bash
# Check VolSync controller logs
kubectl -n volsync-system logs -l control-plane=volsync

# Check ReplicationSource/Destination status
kubectl get replicationsource,replicationdestination -A
```

### OCM Issues

```bash
# Check managed cluster status
kubectl get managedclusters

# Check ManifestWork status
kubectl get manifestwork -A
```

## Differences from OpenShift

| Aspect | OpenShift | RKE2 |
|--------|-----------|------|
| Storage | ODF/Ceph | Longhorn |
| Namespace for Ramen | openshift-dr-system | ramen-system |
| Namespace for ArgoCD | openshift-gitops | argocd |
| CSI Driver | openshift-storage.cephfs.csi.ceph.com | driver.longhorn.io |
| Replication | VolumeReplication (CSI-Addons) | VolSync |

## Next Steps

- [Configure workload protection](configure.md)
- [Perform DR operations](usage.md)
- [Monitor DR status](metrics.md)
