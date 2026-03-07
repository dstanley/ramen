# ArgoCD Integration with OCM Placement for Ramen DR

This directory contains scripts and manifests for setting up ArgoCD with OCM Placement integration for automatic application failover during DR operations.

## Overview

When using ArgoCD ApplicationSet with OCM Placement:
1. ApplicationSet watches PlacementDecision for cluster changes
2. When Ramen updates PlacementDecision during failover/relocate:
   - ArgoCD automatically removes Application from old cluster (prunes resources)
   - ArgoCD automatically creates Application for new cluster
   - ArgoCD syncs application to new cluster

This provides **fully automatic application failover** without manual intervention.

## Setup

### Prerequisites

- ArgoCD installed on hub cluster
- OCM hub components running
- Managed clusters (harv, marv) registered with OCM

### Install ArgoCD

```bash
# Create namespace
kubectl create namespace argocd --context rke2

# Install ArgoCD
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml --context rke2

# Wait for pods to be ready
kubectl wait --for=condition=available --timeout=120s deployment -l app.kubernetes.io/part-of=argocd -n argocd --context rke2
```

### Configure OCM Integration

Run the setup script to configure ArgoCD with OCM Placement integration:

```bash
./setup-argocd-ocm.sh
```

This script:
1. Adds managed clusters (harv, marv) to ArgoCD
2. Creates ConfigMap for PlacementDecision generator
3. Grants ArgoCD permissions to read PlacementDecisions
4. Creates ArgoCD project for DR applications

### Verify Setup

```bash
# Check cluster secrets
kubectl get secrets -n argocd -l argocd.argoproj.io/secret-type=cluster --context rke2

# Check ConfigMap
kubectl get configmap acm-placement -n argocd --context rke2 -o yaml
```

## Usage

### Deploy Application with ArgoCD

```bash
# 1. Create DR resources (namespace, Placement, DRPC) using demo-dr.sh
../scripts/demo-dr.sh deploy harv --model argocd

# 2. Apply the ApplicationSet
kubectl apply -f rto-rpo-applicationset.yaml --context rke2

# 3. Check ArgoCD Applications
kubectl get applications -n argocd --context rke2
```

### Trigger Failover

```bash
# Use the demo script
../scripts/demo-dr.sh failover marv --model argocd

# Or patch DRPC directly
kubectl patch drpc rto-rpo-test-drpc -n ramen-test --context rke2 \
  --type merge -p '{"spec":{"action":"Failover","failoverCluster":"marv"}}'
```

When PlacementDecision changes:
1. ArgoCD ApplicationSet detects the change
2. Old Application is deleted (resources pruned from source cluster)
3. New Application is created for target cluster
4. ArgoCD syncs to target cluster

### Trigger Relocate

```bash
../scripts/demo-dr.sh relocate harv --model argocd
```

ArgoCD handles relocate automatically:
1. When PlacementDecision becomes empty (during quiesce), ArgoCD removes app
2. This frees the PVC for final sync
3. When PlacementDecision points to new cluster, ArgoCD deploys app

## Comparison: ArgoCD vs ManifestWork

| Aspect | ManifestWork Model | ArgoCD Model |
|--------|-------------------|--------------|
| App deployment | Manual via demo script | Automatic via ApplicationSet |
| Failover app cleanup | Manual or app-controller.sh | Automatic |
| Relocate app cleanup | Manual or app-controller.sh | **Automatic** |
| Git integration | None | Full GitOps |
| Complexity | Lower | Higher (requires ArgoCD) |

## Files

| File | Description |
|------|-------------|
| `setup-argocd-ocm.sh` | Script to configure ArgoCD with OCM integration |
| `rto-rpo-applicationset.yaml` | ApplicationSet for test app with OCM Placement |
| `applicationset-inline.yaml` | Alternative ApplicationSet examples |

## Troubleshooting

### ApplicationSet not generating Applications

```bash
# Check ApplicationSet status
kubectl describe applicationset rto-rpo-test -n argocd --context rke2

# Check PlacementDecision
kubectl get placementdecision -n ramen-test -l cluster.open-cluster-management.io/placement=rto-rpo-test-placement --context rke2 -o yaml

# Check ArgoCD logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-applicationset-controller --context rke2
```

### Cluster not connecting

```bash
# Check cluster secret
kubectl get secret cluster-harv -n argocd --context rke2 -o yaml

# Test cluster connection via ArgoCD
kubectl exec -n argocd deploy/argocd-server --context rke2 -- argocd cluster list
```

### Application stuck in sync

```bash
# Check Application status
kubectl describe application rto-rpo-test-harv -n argocd --context rke2

# Check ArgoCD server logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server --context rke2
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Hub Cluster                                     │
│                                                                              │
│  ┌─────────────┐     ┌─────────────────┐     ┌─────────────────────────┐    │
│  │  Placement  │────>│ PlacementDecision│<───│  ArgoCD ApplicationSet  │    │
│  │             │     │  (cluster: harv) │     │  (watches decisions)    │    │
│  └─────────────┘     └────────┬─────────┘     └───────────┬─────────────┘    │
│        ↑                      │                           │                  │
│        │                      │                           │                  │
│        │                      ▼                           ▼                  │
│  ┌─────────────────┐   Ramen updates      ┌─────────────────────────┐       │
│  │DRPlacementControl│   during DR         │   ArgoCD Application    │       │
│  │ (controls DR)   │                      │   (for cluster harv)    │       │
│  └─────────────────┘                      └───────────┬─────────────┘       │
│                                                       │                      │
└───────────────────────────────────────────────────────┼──────────────────────┘
                                                        │ GitOps Sync
                                                        ▼
                                               ┌─────────────────┐
                                               │  Managed Cluster │
                                               │     (harv)       │
                                               │                  │
                                               │  [Application]   │
                                               │  [PVC with data] │
                                               └─────────────────┘
```
