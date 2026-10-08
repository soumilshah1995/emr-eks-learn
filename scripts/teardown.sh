#!/usr/bin/env bash
set -euo pipefail

export AWS_PROFILE=dev
export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION="${AWS_REGION}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_NAME="emr-eks-lab"
VIRTUAL_CLUSTER_NAME="emr-eks-lab-vc"
ROLE_NAME="EMRContainers-JobExecutionRole"
POLICY_NAME="EMRContainersJobExecutionPolicy"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
BUCKET_NAME="${BUCKET_NAME:-emr-on-eks-lab-${ACCOUNT_ID}}"
LOG_GROUP="/emr-on-eks/lab"

VIRTUAL_CLUSTER_ID="$(
  aws emr-containers list-virtual-clusters \
    --states RUNNING SUBMITTED BOOTSTRAPPING ARRESTED \
    --query "virtualClusters[?name=='${VIRTUAL_CLUSTER_NAME}']|[0].id" \
    --output text
)"

if [[ -n "${VIRTUAL_CLUSTER_ID}" && "${VIRTUAL_CLUSTER_ID}" != "None" ]]; then
  echo "Cancelling active EMR job runs..."
  ACTIVE_JOB_IDS="$(
    aws emr-containers list-job-runs \
      --virtual-cluster-id "${VIRTUAL_CLUSTER_ID}" \
      --states PENDING SUBMITTED RUNNING CANCEL_PENDING \
      --query 'jobRuns[].id' \
      --output text
  )"
  for job_id in ${ACTIVE_JOB_IDS}; do
    aws emr-containers cancel-job-run \
      --virtual-cluster-id "${VIRTUAL_CLUSTER_ID}" \
      --id "${job_id}" || true
  done

  while [[ -n "$(
    aws emr-containers list-job-runs \
      --virtual-cluster-id "${VIRTUAL_CLUSTER_ID}" \
      --states PENDING SUBMITTED RUNNING CANCEL_PENDING \
      --query 'jobRuns[].id' \
      --output text
  )" ]]; do
    echo "Waiting for jobs to stop..."
    sleep 15
  done

  echo "Deleting virtual cluster ${VIRTUAL_CLUSTER_ID}..."
  aws emr-containers delete-virtual-cluster --id "${VIRTUAL_CLUSTER_ID}"
fi

if aws eks describe-cluster --name "${CLUSTER_NAME}" >/dev/null 2>&1; then
  echo "Deleting EKS cluster and its one-node managed node group..."
  eksctl delete cluster \
    --name "${CLUSTER_NAME}" \
    --region "${AWS_REGION}" \
    --wait
fi

if aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  aws iam delete-role-policy \
    --role-name "${ROLE_NAME}" \
    --policy-name "${POLICY_NAME}" || true
  aws iam delete-role --role-name "${ROLE_NAME}"
fi

if aws s3api head-bucket --bucket "${BUCKET_NAME}" >/dev/null 2>&1; then
  aws s3 rm "s3://${BUCKET_NAME}" --recursive
  aws s3api delete-bucket --bucket "${BUCKET_NAME}"
fi

if aws logs describe-log-groups \
  --log-group-name-prefix "${LOG_GROUP}" \
  --query "logGroups[?logGroupName=='${LOG_GROUP}'].logGroupName" \
  --output text | grep -qx "${LOG_GROUP}"; then
  aws logs delete-log-group --log-group-name "${LOG_GROUP}"
fi

rm -rf "${ROOT_DIR}/.lab"

echo
echo "Lab resources are deleted."
echo "The default VPC/subnets and the non-billable EMR service-linked role remain."
