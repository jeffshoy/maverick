#!/usr/bin/env bash
set -euo pipefail

kubectl create namespace dev --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -n dev -f - <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-aks
spec:
  replicas: 2
  selector:
    matchLabels:
      app: hello-aks
  template:
    metadata:
      labels:
        app: hello-aks
    spec:
      containers:
      - name: hello-aks
        image: mcr.microsoft.com/azuredocs/aks-helloworld:v1
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"
          limits:
            cpu: "500m"
            memory: "256Mi"
---
apiVersion: v1
kind: Service
metadata:
  name: hello-aks
spec:
  type: ClusterIP
  ports:
  - port: 80
    targetPort: 80
  selector:
    app: hello-aks
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hello-aks
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: hello-aks
            port:
              number: 80
YAML

kubectl get pods -n dev
kubectl get svc -n dev
kubectl get ingress -n dev
