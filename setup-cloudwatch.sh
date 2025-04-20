#!/bin/bash

# Set variables
CLUSTER_NAME="my-cluster"
REGION="us-east-1"
ACCOUNT_ID="405396994912"
NAMESPACE="amazon-cloudwatch"

# 1. Associate OIDC Provider
echo "Associating IAM OIDC Provider..."
eksctl utils associate-iam-oidc-provider \
  --region $REGION \
  --cluster $CLUSTER_NAME \
  --approve

# 2. Create IAM Service Account with CloudWatch Policy
echo "Creating IAM service account for CloudWatch Agent..."
eksctl create iamserviceaccount \
  --region $REGION \
  --name cloudwatch-agent \
  --namespace $NAMESPACE \
  --cluster $CLUSTER_NAME \
  --attach-policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy \
  --approve \
  --override-existing-serviceaccounts

# 3. Create Namespace (if not exists)
echo "Creating namespace $NAMESPACE if not already present..."
kubectl get ns $NAMESPACE || kubectl create namespace $NAMESPACE

# 4. Deploy CloudWatch Agent DaemonSet
echo "Deploying CloudWatch Agent DaemonSet..."
kubectl apply -f https://raw.githubusercontent.com/aws-samples/amazon-cloudwatch-container-insights/main/k8s-deployment-manifest-templates/deployment-mode/daemonset/container-insights-monitoring/cwagent/cwagent-daemonset.yaml

# 5. Deploy Fluent Bit DaemonSet
echo "Deploying Fluent Bit DaemonSet..."
kubectl apply -f https://raw.githubusercontent.com/aws-samples/amazon-cloudwatch-container-insights/main/k8s-deployment-manifest-templates/deployment-mode/daemonset/container-insights-monitoring/fluent-bit/fluent-bit.yaml

# 6. Done
echo "✅ CloudWatch Container Insights setup complete for cluster: $CLUSTER_NAME"
