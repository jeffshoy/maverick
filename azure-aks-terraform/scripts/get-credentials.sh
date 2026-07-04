#!/usr/bin/env bash
set -euo pipefail

RESOURCE_GROUP_NAME="${1:-rg-dev-eastus-aks}"
AKS_CLUSTER_NAME="${2:-aks-dev-eastus-core}"

az aks get-credentials \
  --resource-group "$RESOURCE_GROUP_NAME" \
  --name "$AKS_CLUSTER_NAME" \
  --overwrite-existing

kubectl get nodes -o wide
