# Ramen OTS Setup

Scripts for running Ramen DR with the OTS (Object Transport System) controller
instead of OCM runtime components.

## Overview

The OTS controller replaces OCM's work agent and view controller by fulfilling
ManifestWork and ManagedClusterView CRs directly from the hub cluster using
kubeconfig-based access to managed clusters.

**Controller repo:** https://github.com/dstanley/ramen-ots

## Scripts

### setup-ots.sh

Sets up the OTS controller and managed cluster configuration:
1. Installs OCM CRDs (ManifestWork, ManagedClusterView, ManagedCluster, etc.)
2. Creates managed cluster namespaces and ManagedCluster CRs
3. Creates kubeconfig secrets for managed clusters
4. Deploys the OTS controller

```bash
# Clone the OTS controller repo for deploy manifests
git clone https://github.com/dstanley/ramen-ots.git

# Run setup
./setup-ots.sh --clusters harv,marv \
  --kubeconfig ~/.kube/config \
  --deploy-dir ramen-ots/scripts/deploy \
  --image registry.example.com/ramen-ots:latest
```

### setup-submariner.sh

Configures Submariner for cross-cluster network connectivity (required for
VolSync rsync-based replication between clusters).

## Prerequisites

- Ramen hub operator deployed
- `kubectl` configured to talk to the hub cluster
- Kubeconfig files or contexts for managed clusters
- OTS controller image available in a registry accessible from the hub
