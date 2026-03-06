# Ramen DR Architecture on RKE2/Harvester

This document describes the architecture and components involved in running Ramen Disaster Recovery with Open Cluster Management (OCM) on RKE2 and Harvester clusters.

## Overview

Ramen provides application-level disaster recovery for Kubernetes workloads across multiple clusters. It uses OCM (Open Cluster Management) as the multi-cluster management layer to coordinate DR operations between a hub cluster and managed clusters.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Hub Cluster                                     │
│                         (Control Plane for DR)                               │
│                                                                              │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐              │
│  │   OCM Hub       │  │  Ramen Hub      │  │    MinIO        │              │
│  │   Components    │  │  Operator       │  │   (S3 Store)    │              │
│  └────────┬────────┘  └────────┬────────┘  └────────┬────────┘              │
│           │                    │                    │                        │
│           │    Coordinates     │   Manages DR       │  Stores DR            │
│           │    Multi-cluster   │   Resources        │  Metadata             │
│           │    Operations      │                    │                        │
└───────────┼────────────────────┼────────────────────┼────────────────────────┘
            │                    │                    │
            │ ManifestWork       │ DRCluster          │ S3 API
            │ ManagedClusterView │ DRPolicy           │
            │                    │ DRPlacementControl │
            ▼                    ▼                    ▼
┌───────────────────────────────┐ ┌───────────────────────────────┐
│      Managed Cluster 1        │ │      Managed Cluster 2        │
│         (Primary)             │ │        (Secondary)            │
│                               │ │                               │
│  ┌─────────────────────────┐  │ │  ┌─────────────────────────┐  │
│  │  OCM Klusterlet         │  │ │  │  OCM Klusterlet         │  │
│  │  + Work Manager Addon   │  │ │  │  + Work Manager Addon   │  │
│  └─────────────────────────┘  │ │  └─────────────────────────┘  │
│  ┌─────────────────────────┐  │ │  ┌─────────────────────────┐  │
│  │  Ramen DR Cluster       │  │ │  │  Ramen DR Cluster       │  │
│  │  Operator               │  │ │  │  Operator               │  │
│  └─────────────────────────┘  │ │  └─────────────────────────┘  │
│  ┌─────────────────────────┐  │ │  ┌─────────────────────────┐  │
│  │  VolSync                │  │ │  │  VolSync                │  │
│  │  (Async Replication)    │  │ │  │  (Async Replication)    │  │
│  └─────────────────────────┘  │ │  └─────────────────────────┘  │
│  ┌─────────────────────────┐  │ │  ┌─────────────────────────┐  │
│  │  Longhorn CSI           │  │ │  │  Longhorn CSI           │  │
│  │  (Storage)              │  │ │  │  (Storage)              │  │
│  └─────────────────────────┘  │ │  └─────────────────────────┘  │
│                               │ │                               │
│  [Protected Workloads]        │ │  [Replicated Data]            │
└───────────────────────────────┘ └───────────────────────────────┘
```

---

## Hub Cluster Components

### Open Cluster Management (OCM) Hub

OCM provides the multi-cluster management foundation. On the hub, several controllers work together:

#### Namespace: `open-cluster-management`

| Component | Description |
|-----------|-------------|
| **cluster-manager** | Main OCM operator that manages the lifecycle of hub controllers |
| **multicluster-operators-subscription** | Handles GitOps-style application deployment via Subscriptions and Channels |
| **multicluster-operators-channel** | Manages Channel resources (repositories for deployable content) |
| **multicluster-operators-placementrule** | Evaluates PlacementRules to determine target clusters |
| **multicluster-operators-appsub-summary** | Aggregates subscription status across clusters |
| **ocm-controller** | From stolostron/multicloud-operators-foundation; manages cluster info and addon deployment |

#### Namespace: `open-cluster-management-hub`

| Component | Description |
|-----------|-------------|
| **cluster-manager-registration-controller** | Handles managed cluster registration and CSR approval |
| **cluster-manager-registration-webhook** | Validates ManagedCluster resources |
| **cluster-manager-placement-controller** | Evaluates Placement resources for workload scheduling |
| **cluster-manager-work-webhook** | Validates ManifestWork resources |
| **cluster-manager-addon-manager-controller** | Manages addon lifecycle across managed clusters |

### Ramen Hub Operator

**Namespace:** `ramen-system`

The Ramen hub operator runs on the hub cluster and manages DR at the policy level.

#### Controllers

| Controller | Watches | Creates/Manages | Purpose |
|------------|---------|-----------------|---------|
| **DRCluster Controller** | DRCluster | ManifestWork, ManagedClusterView | Validates clusters, deploys DRClusterConfig to managed clusters, reads cluster capabilities via MCV |
| **DRPolicy Controller** | DRPolicy | - | Validates that referenced DRClusters are healthy and compatible |
| **DRPlacementControl Controller** | DRPlacementControl | VolumeReplicationGroup (via ManifestWork) | Orchestrates failover/relocate operations |

#### Custom Resources (Hub)

| CRD | Scope | Description |
|-----|-------|-------------|
| **DRCluster** | Cluster | Represents a managed cluster participating in DR. Contains S3 profile, region, and CIDRs. |
| **DRPolicy** | Cluster | Defines DR relationship between clusters (which clusters, replication interval) |
| **DRPlacementControl** | Namespaced | Ties a workload (via Placement) to a DRPolicy for protection |

### MinIO (S3 Storage)

**Namespace:** `minio-system`

Provides S3-compatible object storage for:
- VolumeReplicationGroup metadata
- PVC metadata during DR operations
- Cluster state information

Ramen uses S3 as a coordination point between clusters during failover.

---

## Managed Cluster Components

### OCM Klusterlet

The klusterlet is the OCM agent that runs on each managed cluster.

#### Namespace: `open-cluster-management-agent`

| Component | Description |
|-----------|-------------|
| **klusterlet-registration-agent** | Registers the cluster with the hub, maintains heartbeat, handles CSR rotation |
| **klusterlet-work-agent** | Applies ManifestWork resources from the hub to the local cluster |

#### Namespace: `open-cluster-management-agent-addon`

| Component | Description |
|-----------|-------------|
| **application-manager** | Processes Subscription resources for GitOps deployments |
| **klusterlet-addon-workmgr** | **Critical for Ramen**: Processes ManagedClusterView requests from the hub |

### Ramen DR Cluster Operator

**Namespace:** `ramen-system`

The DR cluster operator runs on each managed cluster and handles local DR operations.

#### Controllers

| Controller | Watches | Creates/Manages | Purpose |
|------------|---------|-----------------|---------|
| **DRClusterConfig Controller** | DRClusterConfig | - | Discovers local storage classes, snapshot classes, and reports them in status |
| **VolumeReplicationGroup Controller** | VolumeReplicationGroup | ReplicationSource/Destination, PVC operations | Manages data replication for protected workloads |

#### Custom Resources (Managed Cluster)

| CRD | Scope | Description |
|-----|-------|-------------|
| **DRClusterConfig** | Cluster | Local cluster configuration; status contains discovered storage classes and capabilities |
| **VolumeReplicationGroup** | Namespaced | Defines which PVCs to protect and replication settings |

### VolSync

**Namespace:** `volsync-system`

VolSync provides asynchronous volume replication using rsync-based or Restic-based methods.

| Component | Description |
|-----------|-------------|
| **volsync controller** | Watches ReplicationSource and ReplicationDestination CRs, manages data sync |

#### Custom Resources

| CRD | Description |
|-----|-------------|
| **ReplicationSource** | Defines source PVC and sync schedule (created on primary cluster) |
| **ReplicationDestination** | Defines where to receive replicated data (created on secondary cluster) |

### Longhorn CSI (Harvester)

**Namespace:** `longhorn-system`

Longhorn provides persistent storage on Harvester clusters.

| Component | Description |
|-----------|-------------|
| **longhorn-manager** | Main storage controller |
| **longhorn-csi-plugin** | CSI driver for Kubernetes |
| **longhorn-driver-deployer** | Deploys CSI components |

Ramen integrates with Longhorn via:
- StorageClass with `ramendr.openshift.io/storageid` label
- VolumeSnapshotClass with `ramendr.openshift.io/storageid` label

**Important:** For async (VolSync) replication, each cluster must have a **unique** storageID.
Same storageID across clusters triggers sync replication detection. See the VolSync Configuration section below.

---

## Communication Patterns

### Hub to Managed Cluster (Push)

The hub pushes configuration to managed clusters using **ManifestWork**:

```
Hub                                    Managed Cluster
 │                                           │
 │  ManifestWork                             │
 │  (contains DRClusterConfig,               │
 │   VolumeReplicationGroup, etc.)           │
 │ ─────────────────────────────────────────>│
 │                                           │
 │                        klusterlet-work-agent
 │                        applies resources locally
```

**ManifestWork** is an OCM resource that:
1. Is created in the managed cluster's namespace on the hub (e.g., `harv` namespace for harv cluster)
2. Contains embedded Kubernetes resources to apply
3. Is picked up by the klusterlet-work-agent on the managed cluster
4. Reports back status via ManifestWork.status

### Managed Cluster to Hub (Pull via MCV)

The hub reads resources from managed clusters using **ManagedClusterView**:

```
Hub                                    Managed Cluster
 │                                           │
 │  ManagedClusterView                       │
 │  (request to read DRClusterConfig)        │
 │ ─────────────────────────────────────────>│
 │                                           │
 │                        klusterlet-addon-workmgr
 │                        fetches the resource
 │                                           │
 │  MCV.status.result                        │
 │  (contains DRClusterConfig data)          │
 │ <─────────────────────────────────────────│
```

**ManagedClusterView** allows the hub to:
1. Read any resource from a managed cluster
2. Get the result in MCV.status.result
3. React to changes (via watch/reconcile)

**Important:** MCV requires the `klusterlet-addon-workmgr` agent, which is deployed via the `work-manager` ClusterManagementAddOn.

### Data Replication (VolSync)

VolSync replicates PVC data between clusters:

```
Primary Cluster                      Secondary Cluster
      │                                     │
      │  ReplicationSource                  │  ReplicationDestination
      │  (rsync-tls client)                 │  (rsync-tls server)
      │                                     │
      │         ──── rsync/TLS ────>        │
      │                                     │
      │  PVC data                           │  PVC data (replica)
```

The synchronization happens directly between clusters, not through the hub.

### Cross-Cluster Networking (Submariner)

For production deployments, Submariner provides secure cross-cluster networking:

```
Primary Cluster                      Secondary Cluster
      │                                     │
      │  Submariner Gateway                 │  Submariner Gateway
      │  (IPsec tunnel endpoint)            │  (IPsec tunnel endpoint)
      │                                     │
      │  ════════ IPsec tunnel ═══════════  │
      │                                     │
      │  Lighthouse DNS                     │  Lighthouse DNS
      │  (*.clusterset.local)               │  (*.clusterset.local)
      │                                     │
      │  ServiceExport ────────────────────>│  Service discovery
```

With Submariner:
- VolSync uses `ClusterIP` services (more secure than LoadBalancer)
- Services are discovered via `*.svc.clusterset.local` DNS names
- Traffic is encrypted via IPsec tunnels

---

## DR Operation Flow

### Initial Protection (Deploy)

```
1. User creates DRPlacementControl on hub
   └─> References: Placement, DRPolicy

2. Hub DRPlacementControl controller:
   └─> Creates VolumeReplicationGroup via ManifestWork on primary cluster

3. Primary cluster VRG controller:
   └─> Creates ReplicationSource for each protected PVC
   └─> VolSync begins replicating data

4. Secondary cluster receives ReplicationDestination
   └─> VolSync creates destination PVCs with replicated data
```

### Failover

```
1. User updates DRPlacementControl.spec.action = "Failover"

2. Hub controller:
   └─> Updates VRG on primary to Secondary role (if reachable)
   └─> Creates/updates VRG on secondary to Primary role

3. Secondary cluster:
   └─> VRG controller promotes ReplicationDestination PVCs
   └─> Workload can now run on secondary

4. Application is moved to secondary cluster
```

### Relocate (Planned Migration)

```
1. User updates DRPlacementControl.spec.action = "Relocate"

2. Hub controller:
   └─> Ensures final sync from primary to secondary
   └─> Demotes primary VRG
   └─> Promotes secondary VRG

3. Workload moves to secondary with no data loss
```

---

## Key Custom Resource Relationships

```
                                Hub Cluster
┌──────────────────────────────────────────────────────────────────────────┐
│                                                                          │
│   DRPolicy ◄─────────────────┐                                           │
│   (dr-policy)                │                                           │
│   - drClusters: [harv, marv] │                                           │
│   - schedulingInterval: 5m   │                                           │
│                              │                                           │
│   DRCluster (harv)           │     DRCluster (marv)                      │
│   - s3ProfileName            │     - s3ProfileName                       │
│   - region: east             │     - region: west                        │
│         │                    │           │                               │
│         │                    │           │                               │
│         ▼                    │           ▼                               │
│   ManifestWork ──────────────┼──► ManifestWork                           │
│   (deploys DRClusterConfig)  │    (deploys DRClusterConfig)              │
│                              │                                           │
│   ManagedClusterView ◄───────┼─── ManagedClusterView                     │
│   (reads DRClusterConfig     │    (reads DRClusterConfig                 │
│    status)                   │     status)                               │
│                              │                                           │
│   DRPlacementControl ────────┴──► References DRPolicy                    │
│   (my-app-drpc)                   Creates VRG on target cluster          │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘

                              Managed Clusters
┌─────────────────────────────────┐  ┌─────────────────────────────────┐
│         harv cluster            │  │         marv cluster            │
│                                 │  │                                 │
│   DRClusterConfig               │  │   DRClusterConfig               │
│   - clusterID: harv             │  │   - clusterID: marv             │
│   - status:                     │  │   - status:                     │
│       storageClasses: [...]     │  │       storageClasses: [...]     │
│       snapshotClasses: [...]    │  │       snapshotClasses: [...]    │
│                                 │  │                                 │
│   VolumeReplicationGroup        │  │   VolumeReplicationGroup        │
│   (when workload protected)     │  │   (replica)                     │
│   - pvcSelector: ...            │  │                                 │
│   - replicationState: Primary   │  │   - replicationState: Secondary │
│                                 │  │                                 │
│   ReplicationSource ──────────────────► ReplicationDestination       │
│   (VolSync)                     │  │   (VolSync)                     │
│                                 │  │                                 │
│   Protected PVCs                │  │   Replicated PVCs               │
│                                 │  │                                 │
└─────────────────────────────────┘  └─────────────────────────────────┘
```

---

## Required CRDs by Component

### Hub Cluster

| CRD | Source | Used By |
|-----|--------|---------|
| ManagedCluster | OCM | cluster-manager |
| ManagedClusterSet | OCM | cluster-manager |
| Placement | OCM | placement-controller |
| PlacementRule | OCM (legacy) | Ramen |
| ManifestWork | OCM | work-webhook |
| ManagedClusterView | OCM/stolostron | Ramen hub |
| ManagedClusterAddOn | OCM | addon-manager |
| ClusterManagementAddOn | OCM | addon-manager |
| DRCluster | Ramen | ramen-hub-operator |
| DRPolicy | Ramen | ramen-hub-operator |
| DRPlacementControl | Ramen | ramen-hub-operator |

### Managed Clusters

| CRD | Source | Used By |
|-----|--------|---------|
| Klusterlet | OCM | klusterlet operator |
| AppliedManifestWork | OCM | klusterlet-work-agent |
| ClusterClaim | OCM | klusterlet |
| ManagedServiceAccount | stolostron | application-manager |
| DRClusterConfig | Ramen | ramen-dr-cluster-operator |
| VolumeReplicationGroup | Ramen | ramen-dr-cluster-operator |
| ReplicationSource | VolSync | volsync |
| ReplicationDestination | VolSync | volsync |
| VolumeReplication | CSI Addons | ramen-dr-cluster-operator |
| VolumeReplicationClass | CSI Addons | ramen-dr-cluster-operator |
| NetworkFence | CSI Addons | ramen-dr-cluster-operator |
| NetworkFenceClass | CSI Addons | ramen-dr-cluster-operator |

---

## S3 Storage Usage

Ramen uses S3 for storing DR metadata. The bucket structure:

```
s3://ramen/
├── <cluster-id>/
│   └── vrg/
│       └── <namespace>/
│           └── <vrg-name>/
│               ├── pvc-<name>.json      # PVC metadata
│               └── vrg-status.json      # VRG status
```

This allows:
- Cross-cluster coordination without direct connectivity
- Recovery of PVC metadata during failover
- Audit trail of DR operations

---

## VolSync Configuration

### StorageID Labels (Critical for Async Replication)

Ramen determines replication type based on `ramendr.openshift.io/storageid` labels:

| StorageID Configuration | Replication Type | Method |
|------------------------|------------------|--------|
| **Same** storageID across clusters | Sync | VolumeReplication (CSI-level) |
| **Different** storageIDs per cluster | Async | VolSync (rsync-tls) |

For VolSync-based replication, **each cluster must have a unique storageID**:

```bash
# On cluster "harv"
kubectl label storageclass harvester-longhorn ramendr.openshift.io/storageid=longhorn-harv --overwrite
kubectl label volumesnapshotclass longhorn-snapshot ramendr.openshift.io/storageid=longhorn-harv --overwrite

# On cluster "marv"
kubectl label storageclass harvester-longhorn ramendr.openshift.io/storageid=longhorn-marv --overwrite
kubectl label volumesnapshotclass longhorn-snapshot ramendr.openshift.io/storageid=longhorn-marv --overwrite
```

### VolumeSnapshotClass Selection

Ramen selects VolumeSnapshotClass by matching:
1. The StorageClass's provisioner (driver)
2. The `ramendr.openshift.io/storageid` label

For Longhorn/Harvester, use `longhorn-snapshot` (not `longhorn`):

| Class | Type | Use Case |
|-------|------|----------|
| `longhorn` | Backup-based | Requires external backup target |
| `longhorn-snapshot` | Local snapshot | Works out-of-box, has `type: snap` parameter |

Set `longhorn-snapshot` as default:
```bash
kubectl annotate volumesnapshotclass longhorn-snapshot snapshot.storage.kubernetes.io/is-default-class=true
```

### MoverSecurityContext

VolSync's rsync mover requires specific security settings to avoid "setgid failed" errors.
Configure via DRPC's `volSyncSpec.moverConfig`:

```yaml
apiVersion: ramendr.openshift.io/v1alpha1
kind: DRPlacementControl
metadata:
  name: my-app-drpc
  namespace: my-namespace
spec:
  drPolicyRef:
    name: dr-policy
  placementRef:
    kind: Placement
    name: my-app-placement
  pvcSelector:
    matchLabels:
      app: my-app
  # Required for VolSync rsync-tls to work
  volSyncSpec:
    moverConfig:
    - pvcName: my-pvc
      pvcNamespace: my-namespace
      moverSecurityContext:
        runAsUser: 65534    # nobody
        runAsGroup: 65534
        fsGroup: 65534
```

**Why this is needed:** The rsync daemon tries to drop privileges using `setgid()`. Running as root (UID 0) without CAP_SETGID causes "setgid failed" errors. Running as `nobody` (65534) avoids this.

### Submariner Integration

With Submariner enabled, VolSync uses:
- `ClusterIP` service type (instead of LoadBalancer)
- Cross-cluster DNS: `<service>.<namespace>.svc.clusterset.local`
- ServiceExport for service discovery

Set `is-submariner-enabled` annotation on DRPC:
```yaml
metadata:
  annotations:
    drplacementcontrol.ramendr.openshift.io/is-submariner-enabled: "true"
```

---

## Network Requirements

| Source | Destination | Port | Purpose |
|--------|-------------|------|---------|
| Hub | Managed cluster API | 6443 | ManifestWork, MCV |
| Managed cluster | Hub API | 6443 | Registration, status reporting |
| Managed cluster | Managed cluster | 8000 | VolSync rsync-tls (via Submariner or LoadBalancer) |
| Managed cluster | Managed cluster | 4500/UDP | Submariner IPsec NAT-T |
| Managed cluster | Managed cluster | 4800/UDP | Submariner VXLAN (backup) |
| Managed cluster | Managed cluster | 8080 | Submariner Lighthouse DNS |
| All clusters | MinIO | 9000 | S3 metadata storage |
| All clusters | Container registry | 443/5000 | Image pulls |

**Note:** With Submariner, VolSync traffic flows through the encrypted IPsec tunnel, so only Submariner gateway ports need to be exposed.

---

## Debugging Tips

### Check OCM Communication

```bash
# Hub: Check ManifestWork status
kubectl get manifestwork -n harv -o yaml

# Hub: Check MCV status
kubectl get managedclusterview -n harv -o yaml

# Managed: Check if resources were applied
kubectl get drclusterconfig
kubectl get vrg -A
```

### Check Ramen Controllers

```bash
# Hub operator logs
kubectl logs -n ramen-system deployment/ramen-hub-operator -c manager -f

# DR cluster operator logs (on managed cluster)
kubectl logs -n ramen-system deployment/ramen-dr-cluster-operator -c manager -f
```

### Check VolSync

```bash
# Check replication status
kubectl get replicationsource -A
kubectl get replicationdestination -A

# Check sync status
kubectl describe replicationsource -n <namespace> <name>
```

### Common Issues

| Symptom | Likely Cause | Check |
|---------|--------------|-------|
| DRCluster not validated | MCV not working | `kubectl get managedclusterview -A` |
| VRG not created | ManifestWork not applied | `kubectl get manifestwork -n <cluster>` |
| Data not replicating | VolSync misconfigured | `kubectl get replicationsource -A` |
| Failover fails | S3 connectivity | Check S3 secret, bucket existence |

---

## Component Version Matrix

| Component | Version | Notes |
|-----------|---------|-------|
| clusteradm | v0.11.2 | Must use this version for application-manager addon |
| OCM | 0.16.x | Installed via clusteradm |
| multicloud-operators-foundation | main | For work-manager addon |
| Ramen | dev | Built from source |
| VolSync | 0.10.x | Helm chart |
| Longhorn | 1.7.x | Bundled with Harvester |
| Submariner | 0.22.1+ | Required for K8s 1.34+; v0.18.x has network discovery bugs |

**Submariner Version Note:** Versions prior to 0.22.x have issues with Kubernetes 1.34+ network discovery. The error manifests as "could not determine the service IP range" during `subctl join`.
