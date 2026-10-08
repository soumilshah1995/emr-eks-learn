#!/usr/bin/env bash
set -euo pipefail

export AWS_PROFILE=dev
export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION="${AWS_REGION}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_NAME="emr-eks-lab"
NAMESPACE="emr-eks"
VIRTUAL_CLUSTER_NAME="emr-eks-lab-vc"
ROLE_NAME="EMRContainers-JobExecutionRole"
POLICY_NAME="EMRContainersJobExecutionPolicy"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
BUCKET_NAME="${BUCKET_NAME:-emr-on-eks-lab-${ACCOUNT_ID}}"
LOG_GROUP="/emr-on-eks/lab"

mkdir -p "${ROOT_DIR}/.lab"

aws eks update-kubeconfig --name "${CLUSTER_NAME}"

kubectl create namespace "${NAMESPACE}" \
  --dry-run=client -o yaml | kubectl apply -f -

# This creates namespace-scoped RBAC and maps the EMR Containers service role.
if eksctl get iamidentitymapping \
  --cluster "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" | grep -q "emr-containers"; then
  echo "EMR identity mapping already exists."
else
  eksctl create iamidentitymapping \
    --cluster "${CLUSTER_NAME}" \
    --region "${AWS_REGION}" \
    --namespace "${NAMESPACE}" \
    --service-name emr-containers
fi

if ! aws s3api head-bucket --bucket "${BUCKET_NAME}" >/dev/null 2>&1; then
  aws s3api create-bucket --bucket "${BUCKET_NAME}"
fi

if ! aws logs describe-log-groups \
  --log-group-name-prefix "${LOG_GROUP}" \
  --query "logGroups[?logGroupName=='${LOG_GROUP}'].logGroupName" \
  --output text | grep -qx "${LOG_GROUP}"; then
  aws logs create-log-group --log-group-name "${LOG_GROUP}"
fi

if ! aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  aws iam create-role \
    --role-name "${ROLE_NAME}" \
    --assume-role-policy-document "file://${ROOT_DIR}/iam/job-execution-trust.json" \
    --description "EMR on EKS lab Spark job execution role"
fi

POLICY_FILE="$(mktemp)"
sed -e "s/XXXXXXXXXXXX/${ACCOUNT_ID}/g" \
  -e "s/emr-on-eks-lab-XXXXXXXXXXXX/${BUCKET_NAME}/g" \
  "${ROOT_DIR}/iam/job-execution-policy.json" >"${POLICY_FILE}"
aws iam put-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-name "${POLICY_NAME}" \
  --policy-document "file://${POLICY_FILE}"
rm -f "${POLICY_FILE}"

aws emr-containers update-role-trust-policy \
  --cluster-name "${CLUSTER_NAME}" \
  --namespace "${NAMESPACE}" \
  --role-name "${ROLE_NAME}"

VIRTUAL_CLUSTER_ID="$(
  aws emr-containers list-virtual-clusters \
    --states RUNNING SUBMITTED BOOTSTRAPPING \
    --query "virtualClusters[?name=='${VIRTUAL_CLUSTER_NAME}']|[0].id" \
    --output text
)"

if [[ -z "${VIRTUAL_CLUSTER_ID}" || "${VIRTUAL_CLUSTER_ID}" == "None" ]]; then
  VIRTUAL_CLUSTER_ID="$(
    aws emr-containers create-virtual-cluster \
      --name "${VIRTUAL_CLUSTER_NAME}" \
      --container-provider "{
        \"id\": \"${CLUSTER_NAME}\",
        \"type\": \"EKS\",
        \"info\": {\"eksInfo\": {\"namespace\": \"${NAMESPACE}\"}}
      }" \
      --query id \
      --output text
  )"
fi

printf '%s\n' "${VIRTUAL_CLUSTER_ID}" >"${ROOT_DIR}/.lab/virtual-cluster-id"

echo "Virtual cluster:"
aws emr-containers describe-virtual-cluster --id "${VIRTUAL_CLUSTER_ID}"
echo
echo "Job execution role:"
aws iam get-role --role-name "${ROLE_NAME}" --query 'Role.Arn' --output text
