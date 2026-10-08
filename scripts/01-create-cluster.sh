#!/usr/bin/env bash
set -euo pipefail

export AWS_PROFILE=dev
export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION="${AWS_REGION}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_NAME="emr-eks-lab"

for command in aws kubectl eksctl; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    echo "Missing required command: ${command}" >&2
    exit 1
  fi
done

echo "Using AWS identity:"
aws sts get-caller-identity

if aws eks describe-cluster --name "${CLUSTER_NAME}" >/dev/null 2>&1; then
  echo "EKS cluster ${CLUSTER_NAME} already exists; skipping creation."
  aws eks update-kubeconfig --name "${CLUSTER_NAME}"
else
  eksctl create cluster --config-file "${ROOT_DIR}/cluster.yaml"
fi

echo "Waiting for the single managed node to become Ready..."
kubectl wait --for=condition=Ready node --all --timeout=10m
kubectl get nodes -o wide

echo
echo "This lab has a fixed node group: desired=1, min=1, max=1."
echo "Cluster Autoscaler and Karpenter are not installed."
