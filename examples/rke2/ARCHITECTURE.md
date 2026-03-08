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

#### OCM Governance Policy Framework (Required for VolSync)

The governance policy framework enables Ramen to propagate VolSync secrets between clusters automatically.

**Namespace:** `open-cluster-management-hub`

| Component | Description |
|-----------|-------------|
| **governance-policy-propagator** | Propagates Policy resources to managed clusters via ManifestWork |

**Custom Resources:**

| CRD | API Group | Description |
|-----|-----------|-------------|
| **Policy** | `policy.open-cluster-management.io/v1` | Defines a policy containing objects to enforce on managed clusters |
| **PlacementBinding** | `policy.open-cluster-management.io/v1` | Binds a Policy to a Placement/PlacementRule for cluster selection |

**Why This is Required:**

Ramen uses OCM Policy to propagate VolSync PSK (Pre-Shared Key) secrets to managed clusters. Without the governance policy framework:
- VolSync secrets must be manually copied to each cluster
- DRPC will show errors: `no matches for kind "Policy" in version "policy.open-cluster-management.io/v1"`
- Replication will fail until secrets are manually created

**Important:** A `ManagedClusterSetBinding` must exist in the application namespace for the PlacementRule controller to discover managed clusters. Without it, the Policy that propagates the PSK secret will never be placed on any cluster. See the `demo-dr.sh` script for an example.

**Installation:**

```bash
# Install on hub
clusteradm install hub-addon --names governance-policy-framework

# Enable on managed clusters
clusteradm addon enable --names governance-policy-framework --clusters <cluster1>,<cluster2>
clusteradm addon enable --names config-policy-controller --clusters <cluster1>,<cluster2>
```

### Ramen Hub Operator

**Namespace:** `ramen-system`

The Ramen hub operator runs on the hub cluster and manages DR at the policy level.

#### Controllers

| Controller | Watches | Creates/Manages | Purpose |
|------------|---------|-----------------|---------|
| **DRCluster Controller** | DRCluster | ManifestWork, ManagedClusterView | Validates clusters, deploys DRClusterConfig to managed clusters, reads cluster capabilities via MCV |
| **DRPolicy Controller** | DRPolicy | - | Validates that referenced DRClusters are healthy and compatible |
| **DRPlacementControl Controller** | DRPlacementControl | VolumeReplicationGroup (via ManifestWork), Policy (for VolSync secrets) | Orchestrates failover/relocate operations, propagates VolSync PSK secrets via OCM Policy |

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
| **governance-policy-framework** | **Required for VolSync**: Syncs Policy resources from hub, creates local policy objects |
| **config-policy-controller** | **Required for VolSync**: Enforces ConfigurationPolicy resources (creates/updates secrets) |

**Note:** Without `governance-policy-framework` and `config-policy-controller`, VolSync PSK secrets will not be automatically propagated to managed clusters.

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

## OCM Application Deployment Models

Ramen supports applications deployed via different OCM deployment models. Understanding these models is critical because **how your application is deployed determines whether failover completes automatically or requires manual intervention**.

### Model 1: OCM Subscription/Channel (Recommended for DR)

OCM Subscriptions provide GitOps-style application deployment with automatic cluster placement.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Hub Cluster                                     │
│                                                                              │
│  ┌─────────────┐     ┌─────────────┐     ┌─────────────────────────────┐    │
│  │   Channel   │────>│Subscription │────>│      PlacementRule/         │    │
│  │  (Git repo) │     │ (selects    │     │       Placement             │    │
│  │             │     │  packages)  │     │  (selects target clusters)  │    │
│  └─────────────┘     └──────┬──────┘     └──────────────┬──────────────┘    │
│                             │                           │                    │
│                             │                           ▼                    │
│                             │              ┌─────────────────────────┐       │
│                             │              │   PlacementDecision     │       │
│                             │              │   (cluster: harv)       │       │
│                             │              └───────────┬─────────────┘       │
│                             │                          │                     │
│                             ▼                          ▼                     │
│                    subscription-controller watches PlacementDecision         │
│                    and deploys to selected cluster                           │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ ManifestWork (app resources)
                                    ▼
                           ┌─────────────────┐
                           │  Managed Cluster │
                           │     (harv)       │
                           │                  │
                           │  [Application]   │
                           └─────────────────┘
```

**Key Components:**

| Resource | Purpose |
|----------|---------|
| **Channel** | Points to a source repository (Git, Helm, ObjectBucket, or Namespace) containing deployable content |
| **Subscription** | Selects what to deploy from a Channel (package filters, version) and references a Placement |
| **Placement/PlacementRule** | Defines criteria for selecting target clusters (labels, claims, etc.) |
| **PlacementDecision** | Created by placement-controller; contains the actual list of selected clusters |

**How Subscription Deployment Works:**

1. User creates a Channel pointing to a Git repo with Kubernetes manifests
2. User creates a Subscription referencing the Channel and a Placement
3. Placement controller evaluates cluster criteria and creates a PlacementDecision
4. Subscription controller watches PlacementDecision and creates ManifestWorks for selected clusters
5. Klusterlet work-agent on each managed cluster applies the manifests

**How Subscription Interacts with PlacementDecision Changes:**

When Ramen updates the PlacementDecision during failover:
- The subscription controller **detects** the PlacementDecision change
- When a **new cluster is added** to decisions, it **automatically creates** ManifestWorks to deploy the application
- **Application deployment on new primary is automatic**

**⚠️ Known Limitation: Source Cluster Cleanup During Relocate**

During relocate operations, Ramen temporarily empties the PlacementDecision to quiesce the application on the source cluster. However:

1. The subscription controller **does NOT remove** the ManifestWork when PlacementDecision becomes empty
2. The application keeps running on the source cluster, preventing PVC final sync
3. **Manual intervention may be required** to delete the ManifestWork from the source cluster namespace on the hub

**Workaround for Relocate:**
```bash
# If relocate is stuck at RunningFinalSync, check for orphaned ManifestWork
kubectl get manifestwork -n <source-cluster-namespace> | grep <app-name>

# Delete the orphaned ManifestWork to allow application cleanup
kubectl delete manifestwork <app-manifestwork-name> -n <source-cluster-namespace>
```

This is expected behavior per OCM design - the subscription controller is designed for GitOps workflows where the subscription lifecycle manages the app lifecycle. For DR, Ramen manipulates the PlacementDecision rather than the subscription, which doesn't trigger automatic cleanup.

### Model 2: ArgoCD ApplicationSet

ArgoCD ApplicationSets provide GitOps deployment with OCM Placement integration.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Hub Cluster                                     │
│                                                                              │
│  ┌──────────────────────┐     ┌─────────────────────────────┐               │
│  │    ApplicationSet    │────>│      Placement              │               │
│  │  (Git repo + template│     │  (selects target clusters)  │               │
│  │   for Application)   │     └──────────────┬──────────────┘               │
│  └──────────┬───────────┘                    │                              │
│             │                                ▼                              │
│             │                   ┌─────────────────────────┐                 │
│             │                   │   PlacementDecision     │                 │
│             │                   │   (cluster: harv)       │                 │
│             │                   └───────────┬─────────────┘                 │
│             │                               │                               │
│             ▼                               ▼                               │
│  ApplicationSet controller watches PlacementDecision                        │
│  and creates Application resources for each cluster                         │
│             │                                                               │
│             ▼                                                               │
│  ┌────────────────────┐                                                     │
│  │    Application     │  (ArgoCD syncs to managed cluster)                  │
│  │  (for cluster harv)│                                                     │
│  └────────────────────┘                                                     │
└─────────────────────────────────────────────────────────────────────────────┘
```

**How ApplicationSet Deployment Works:**

1. User creates an ApplicationSet with a ClusterDecisionResource generator pointing to a Placement
2. Placement controller creates PlacementDecision with selected clusters
3. ApplicationSet controller creates an Application resource for each cluster in PlacementDecision
4. ArgoCD syncs each Application to its target cluster

**DR Behavior:**

When Ramen updates the PlacementDecision:
- ApplicationSet controller **automatically creates** new Application for the new cluster
- ArgoCD **automatically syncs** the application to the new cluster
- **Automatic failover** - no manual intervention required

**⚠️ Critical: PVC Ownership**

The ApplicationSet **must not** include PVC manifests. Ramen manages PVC lifecycle during DR operations (creation from snapshots, replication, promotion/demotion). If ArgoCD also tracks the PVC, dual ownership causes conflicts:

1. During failover, ArgoCD's PVC on the source cluster isn't cleaned up
2. The secondary VRG detects a PVC that isn't a VolSync replication destination
3. VRG reports `NoClusterDataConflict` and DR stalls

**Solution:** Use the `directory.include` filter to exclude PVC manifests:
```yaml
directory:
  include: '{namespace.yaml,configmap.yaml,deployment.yaml}'
```

Create the initial PVC separately (e.g., via ManifestWork or deployment script) before enabling DR protection.

### Model 3: ManifestWork Only (Manual Application Deployment)

If your application is deployed directly via kubectl, Helm, or other methods without OCM Subscription or ArgoCD, Ramen cannot automatically move the application.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Hub Cluster                                     │
│                                                                              │
│  ┌─────────────────────────────┐                                            │
│  │        Placement            │                                            │
│  │  (selects target clusters)  │                                            │
│  └──────────────┬──────────────┘                                            │
│                 │                                                           │
│                 ▼                                                           │
│  ┌─────────────────────────┐                                                │
│  │   PlacementDecision     │  <── Ramen updates this during failover        │
│  │   (cluster: harv)       │                                                │
│  └─────────────────────────┘                                                │
│                 │                                                           │
│                 ▼                                                           │
│  ❌ No controller watching PlacementDecision for app deployment             │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘

                    Managed Cluster (harv)
                    ┌─────────────────────────────┐
                    │  [VRG created by Ramen]     │  ✓ Automatic
                    │  [PVCs restored]            │  ✓ Automatic
                    │  [Application]              │  ❌ Manual deployment needed
                    └─────────────────────────────┘
```

**DR Behavior:**

When Ramen updates the PlacementDecision:
- Ramen creates VRG via ManifestWork ✓
- VRG restores PVCs from replication ✓
- **Application must be manually deployed** ❌
- Failover is **incomplete** until user deploys the application

### Model 4: Rancher Fleet GitRepo

Fleet is Rancher's built-in GitOps engine. It deploys workloads from Git repositories to downstream clusters using a pull-based architecture.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Hub Cluster                                     │
│                                                                              │
│  ┌──────────────────────┐     ┌─────────────────────────────┐               │
│  │      GitRepo         │────>│      Cluster Selector       │               │
│  │  (Git repo + path    │     │  ramen.dr/fleet-enabled=true│               │
│  │   for manifests)     │     └──────────────┬──────────────┘               │
│  └──────────┬───────────┘                    │                              │
│             │                                ▼                              │
│             │                   ┌─────────────────────────┐                 │
│             │                   │   Fleet Cluster (harv)  │                 │
│             │                   │   c-npk9v               │                 │
│             │                   └───────────┬─────────────┘                 │
│             │                               │                               │
│             ▼                               ▼                               │
│  Fleet controller creates BundleDeployment for matching cluster             │
│             │                                                               │
│             ▼                                                               │
│  ┌────────────────────┐                                                     │
│  │  BundleDeployment  │  (Fleet agent pulls and deploys)                    │
│  │  (for cluster harv)│                                                     │
│  └────────────────────┘                                                     │
└─────────────────────────────────────────────────────────────────────────────┘
```

**How Fleet Deployment Works:**

1. User creates a GitRepo pointing to a Git repository with application manifests
2. GitRepo uses `clusterSelector` to target clusters with `ramen.dr/fleet-enabled=true`
3. `fleet-dr-controller.sh` watches PlacementDecision and labels/unlabels Fleet Cluster resources
4. Fleet controller creates BundleDeployment for matching clusters
5. Fleet agent on the managed cluster pulls and deploys the resources

**Fleet Cluster Naming:**

Fleet uses auto-generated cluster IDs (e.g., `c-npk9v`) rather than friendly names. The display name is available via the `management.cattle.io/cluster-display-name` label. The DR controller translates between OCM cluster names and Fleet IDs.

**DR Behavior:**

When Ramen updates the PlacementDecision:
- `fleet-dr-controller.sh` detects the change and relabels Fleet clusters
- Fleet **automatically removes** BundleDeployment from the old cluster
- Fleet **automatically creates** BundleDeployment for the new cluster
- Fleet agent deploys the application on the new cluster
- **Automatic failover and relocate** - no manual intervention required

**PVC Ownership:**

The GitRepo **must not** include PVC manifests. A `.fleetignore` file in the app directory excludes `pvc.yaml`. This is the Fleet equivalent of ArgoCD's `directory.include` filter.

### Comparison: Failover vs Relocate Behavior by Deployment Model

#### Failover (Source cluster unavailable)

| Step | OCM Subscription | ArgoCD ApplicationSet | Fleet GitRepo | ManifestWork Only |
|------|------------------|----------------------|---------------|-------------------|
| Ramen updates PlacementDecision | ✓ Automatic | ✓ Automatic | ✓ Automatic | ✓ Automatic |
| VRG created on target cluster | ✓ Automatic | ✓ Automatic | ✓ Automatic | ✓ Automatic |
| PVCs restored/promoted | ✓ Automatic | ✓ Automatic | ✓ Automatic | ✓ Automatic |
| Application deployed to target | ✓ **Automatic** | ✓ **Automatic** | ✓ **Automatic** | ❌ **Manual** |
| Failover completes without intervention | ✓ Yes | ✓ Yes | ✓ Yes | ❌ No |

#### Relocate (Both clusters available, requires final sync)

| Step | OCM Subscription | ArgoCD ApplicationSet | Fleet GitRepo | ManifestWork Only |
|------|------------------|----------------------|---------------|-------------------|
| Ramen empties PlacementDecision | ✓ Automatic | ✓ Automatic | ✓ Automatic | ✓ Automatic |
| Application removed from source | ⚠️ **Manual** (see note) | ✓ Automatic | ✓ Automatic | ❌ Manual |
| Final sync completes | ✓ After cleanup | ✓ Automatic | ✓ Automatic | ⚠️ May block |
| VRG created on target | ✓ Automatic | ✓ Automatic | ✓ Automatic | ✓ Automatic |
| Application deployed to target | ✓ **Automatic** | ✓ **Automatic** | ✓ **Automatic** | ❌ **Manual** |
| Relocate completes without intervention | ⚠️ May need manual cleanup | ✓ Yes | ✓ Yes | ❌ No |

**⚠️ OCM Subscription Note:** The subscription controller does not automatically remove ManifestWork when PlacementDecision becomes empty. During relocate, you may need to manually delete the app ManifestWork from the source cluster namespace on the hub to allow the final sync to complete.

### Recommendation

**For production DR with relocate support:** Consider ArgoCD ApplicationSet or Fleet GitRepo as both handle failover and relocate automatically.

**If using Rancher:** Fleet is the natural choice since it's already installed. No additional components needed.

**For failover-only scenarios:** OCM Subscription works well - the application is automatically deployed to the target cluster.

**If using ManifestWork-only deployment:** Be prepared to manually deploy applications and clean up the source during DR operations.

### How Ramen Detects Deployment Model

Ramen determines the deployment model by examining the Placement reference:

```go
// Simplified logic from drplacementcontrol_controller.go
func getVRGNamespace(placement) string {
    // Check if an ApplicationSet references this Placement
    appSets := listApplicationSets()
    for appSet := range appSets {
        if appSet.usesPlacement(placement) {
            // ApplicationSet model: use destination namespace from AppSet
            return appSet.Spec.Template.Spec.Destination.Namespace
        }
    }
    // Subscription model (default): use Placement namespace
    return placement.Namespace
}
```

---

## DR Operation Flow

### Initial Protection (Deploy)

```
1. User creates DRPlacementControl on hub
   └─> References: Placement, DRPolicy

2. Hub DRPlacementControl controller:
   └─> Creates VolumeReplicationGroup via ManifestWork on primary cluster
   └─> Creates VRG (secondary) via ManifestWork on secondary cluster

3. Primary cluster VRG controller:
   └─> Creates ReplicationSource for each protected PVC
   └─> VolSync begins replicating data

4. Secondary cluster VRG controller:
   └─> Creates ReplicationDestination for each protected PVC
   └─> VolSync creates destination PVCs with replicated data

5. Hub updates DRPC status
   └─> Phase: Deployed, PeerReady: True
```

### Failover

```
1. User updates DRPlacementControl.spec.action = "Failover"
   └─> Sets failoverCluster to target cluster

2. Hub DRPC controller - Progression: FailingOverToCluster
   └─> Updates VRG on primary to Secondary role (if reachable)
   └─> Updates VRG on target to Primary role via ManifestWork

3. Target cluster VRG controller - Progression: WaitingForResourceRestore
   └─> Promotes ReplicationDestination PVCs to regular PVCs
   └─> Restores PV metadata from S3
   └─> Restores application resources from S3 (if kubeObjectProtection enabled)

4. Hub DRPC controller - Progression: UpdatingPlacement
   └─> Updates PlacementDecision to point to target cluster
   └─> This triggers application deployment (see deployment model)

5. Application controller reacts (model-dependent):
   ├─> OCM Subscription: subscription-controller deploys app to target
   ├─> ArgoCD: ApplicationSet creates Application for target cluster
   └─> ManifestWork only: ❌ NO AUTOMATIC DEPLOYMENT - manual intervention needed

6. Hub DRPC controller - Progression: Completed
   └─> Cleans up secondary VRG on source cluster
   └─> Sets up replication in reverse direction
```

**Failover State Machine:**

```
Initiating
    │
    ▼
FailingOverToCluster
    │
    ▼
WaitingForResourceRestore  ──────────────┐
    │                                    │
    ▼                                    │ (VRG not ready, loop back)
WaitForReadiness                         │
    │                                    │
    ├────────────────────────────────────┘
    │
    ▼
UpdatingPlacement  ◄── PlacementDecision updated here
    │
    ▼
Completed / CleaningUp
    │
    ▼
SettingUpVolSyncDest  (reverse replication)
```

### Relocate (Planned Migration)

```
1. User updates DRPlacementControl.spec.action = "Relocate"
   └─> Sets failoverCluster to target cluster

2. Hub DRPC controller - Progression: PreparingFinalSync
   └─> Ensures application is quiesced on source
   └─> Triggers final sync via VRG

3. Source cluster VRG controller - Progression: RunningFinalSync
   └─> Initiates PVC deletion (triggers final VolSync)
   └─> Waits for final sync to complete

4. Hub DRPC controller - Progression: EnsuringVolumesAreSecondary
   └─> Demotes source VRG to Secondary
   └─> Waits for demotion to complete

5. Hub DRPC controller - Progression: WaitingForResourceRestore
   └─> Promotes target VRG to Primary
   └─> Restores PVCs and app resources on target

6. Hub DRPC controller - Progression: UpdatingPlacement
   └─> Updates PlacementDecision to point to target cluster
   └─> Application controller deploys to target (model-dependent)

7. Hub DRPC controller - Progression: Completed
   └─> Sets up replication in reverse direction
```

**Relocate State Machine:**

```
Initiating
    │
    ▼
PreparingFinalSync
    │
    ▼
RunningFinalSync  ◄── PVC deletion initiated here
    │
    ▼
EnsuringVolumesAreSecondary
    │
    ▼
WaitingForResourceRestore
    │
    ▼
UpdatingPlacement  ◄── PlacementDecision updated here
    │
    ▼
Completed / CleaningUp
    │
    ▼
SettingUpVolSyncDest  (reverse replication)
```

### Common Issues by Deployment Model

| Issue | Symptom | Cause | Solution |
|-------|---------|-------|----------|
| Failover stuck at WaitingForResourceRestore | VRG not becoming Primary | PVCs not restored, S3 access issue | Check VRG status, S3 connectivity |
| Failover completes but app not running | DRPC shows Completed, no pods | ManifestWork-only deployment | Deploy app manually or use Subscription |
| PlacementDecision not updating | DRPC stuck at UpdatingPlacement | Placement controller issue | Check placement-controller logs |
| App deployed to wrong namespace | Pods in unexpected namespace | ApplicationSet namespace mismatch | Verify AppSet template destination |

---

## Example: Setting Up OCM Subscription for Automatic Failover

This example shows how to set up an OCM Subscription-based deployment that will automatically failover with Ramen.

### 1. Create a Channel (Git Repository)

```yaml
apiVersion: apps.open-cluster-management.io/v1
kind: Channel
metadata:
  name: my-app-channel
  namespace: my-app-channel-ns
spec:
  type: Git
  pathname: https://github.com/example/my-app-manifests.git
```

### 2. Create a Placement

```yaml
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Placement
metadata:
  name: my-app-placement
  namespace: my-app-ns
spec:
  predicates:
    - requiredClusterSelector:
        labelSelector:
          matchLabels:
            cluster.open-cluster-management.io/clusterset: dr-clusters
  # Ramen will manage the cluster selection via PlacementDecision
```

### 3. Create a Subscription

```yaml
apiVersion: apps.open-cluster-management.io/v1
kind: Subscription
metadata:
  name: my-app-subscription
  namespace: my-app-ns
  annotations:
    apps.open-cluster-management.io/git-path: deploy/
    apps.open-cluster-management.io/git-branch: main
spec:
  channel: my-app-channel-ns/my-app-channel
  placement:
    placementRef:
      kind: Placement
      name: my-app-placement
```

### 4. Create a DRPlacementControl

```yaml
apiVersion: ramendr.openshift.io/v1alpha1
kind: DRPlacementControl
metadata:
  name: my-app-drpc
  namespace: my-app-ns
spec:
  preferredCluster: harv
  drPolicyRef:
    name: dr-policy
  placementRef:
    kind: Placement
    name: my-app-placement
  pvcSelector:
    matchLabels:
      app: my-app
```

### How It Works Together

```
1. Initial Deployment:
   ┌─────────────────────────────────────────────────────────────────┐
   │ Placement → PlacementDecision (cluster: harv)                   │
   │     ↓                                                           │
   │ Subscription controller sees PlacementDecision                  │
   │     ↓                                                           │
   │ Creates ManifestWork to deploy app on harv                      │
   │     ↓                                                           │
   │ DRPC creates VRG on harv (Primary) and marv (Secondary)         │
   └─────────────────────────────────────────────────────────────────┘

2. After Failover (action: Failover, failoverCluster: marv):
   ┌─────────────────────────────────────────────────────────────────┐
   │ DRPC promotes VRG on marv to Primary                            │
   │     ↓                                                           │
   │ DRPC updates PlacementDecision (cluster: marv)                  │
   │     ↓                                                           │
   │ Subscription controller detects PlacementDecision change        │
   │     ↓                                                           │
   │ Deletes ManifestWork for harv, creates ManifestWork for marv    │
   │     ↓                                                           │
   │ App automatically deployed on marv ✓                            │
   └─────────────────────────────────────────────────────────────────┘
```

### Verifying Subscription Setup

```bash
# Check Channel
kubectl get channel -A

# Check Subscription
kubectl get subscription -n my-app-ns

# Check Placement and PlacementDecision
kubectl get placement -n my-app-ns
kubectl get placementdecision -n my-app-ns

# After failover, verify PlacementDecision was updated
kubectl get placementdecision -n my-app-ns -o yaml | grep -A5 decisions
```

### Required OCM Components

For OCM Subscriptions to work, ensure these components are installed:

**On Hub:**
- `multicluster-operators-subscription` (from stolostron/multicloud-operators-subscription)
- `multicluster-operators-channel`
- `multicluster-operators-placementrule` (legacy) or placement-controller

**On Managed Clusters:**
- `application-manager` addon (from work-manager ClusterManagementAddOn)

Verify with:
```bash
# Hub
kubectl get pods -n open-cluster-management | grep -E "subscription|channel|placement"

# Managed cluster
kubectl get pods -n open-cluster-management-agent-addon | grep application-manager
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
| **Policy** | **OCM Governance** | **Ramen hub (VolSync secret propagation)** |
| **PlacementBinding** | **OCM Governance** | **Ramen hub (binds Policy to clusters)** |
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
| **ConfigurationPolicy** | **OCM Governance** | **config-policy-controller (enforces secrets)** |
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

### Check Policy Framework (VolSync Secret Propagation)

```bash
# Verify Policy CRDs exist on hub
kubectl get crd | grep -E "policies.policy.open-cluster-management|placementbindings"

# Check if policy addons are available on managed clusters
kubectl get managedclusteraddons -A | grep -E "policy|config"

# Check Policy resources for a DRPC (on hub)
kubectl get policy -n <app-namespace>

# Check if Policy shows Compliant (on hub)
kubectl get policy -n <app-namespace> -o wide

# Check hub operator logs for policy errors
kubectl logs -n ramen-system deployment/ramen-hub-operator -c manager | grep -i policy

# Verify secret exists on managed cluster
kubectl get secret <drpc-name>-vs-secret -n <app-namespace>
```

### Common Issues

| Symptom | Likely Cause | Check |
|---------|--------------|-------|
| DRCluster not validated | MCV not working | `kubectl get managedclusterview -A` |
| VRG not created | ManifestWork not applied | `kubectl get manifestwork -n <cluster>` |
| Data not replicating | VolSync misconfigured | `kubectl get replicationsource -A` |
| Failover fails | S3 connectivity | Check S3 secret, bucket existence |
| **VolSync secret not found** | **Policy CRDs missing** | **`kubectl get crd \| grep policies`** |
| **Hub logs: "no matches for kind Policy"** | **governance-policy-framework not installed** | **`clusteradm install hub-addon --names governance-policy-framework`** |
| **ReplicationDestination not created** | **PSK secret missing on secondary** | **Check policy compliance: `kubectl get policy -n <ns>`** |

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
