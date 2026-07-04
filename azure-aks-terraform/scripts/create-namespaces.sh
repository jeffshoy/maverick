#!/usr/bin/env bash
set -euo pipefail

kubectl create namespace dev --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace test --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace prod --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace ingress-basic --dry-run=client -o yaml | kubectl apply -f -

kubectl get namespaces
