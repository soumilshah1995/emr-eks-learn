#!/usr/bin/env bash
set -euo pipefail

export AWS_PROFILE=dev
export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION="${AWS_REGION}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VIRTUAL_CLUSTER_NAME="emr-eks-lab-vc"
ROLE_NAME="EMRContainers-JobExecutionRole"
LOG_GROUP="/emr-on-eks/lab"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
BUCKET_NAME="${BUCKET_NAME:-emr-on-eks-lab-${ACCOUNT_ID}}"
RELEASE_LABEL="emr-7.10.0-latest"

mkdir -p "${ROOT_DIR}/.lab"

VIRTUAL_CLUSTER_ID="$(
  aws emr-containers list-virtual-clusters \
    --states RUNNING \
    --query "virtualClusters[?name=='${VIRTUAL_CLUSTER_NAME}']|[0].id" \
    --output text
)"
if [[ -z "${VIRTUAL_CLUSTER_ID}" || "${VIRTUAL_CLUSTER_ID}" == "None" ]]; then
  echo "No running virtual cluster named ${VIRTUAL_CLUSTER_NAME}." >&2
  echo "Run scripts/02-enable-emr.sh first." >&2
  exit 1
fi

ROLE_ARN="$(
  aws iam get-role \
    --role-name "${ROLE_NAME}" \
    --query 'Role.Arn' \
    --output text
)"

JOB_ID="$(
  aws emr-containers start-job-run \
    --virtual-cluster-id "${VIRTUAL_CLUSTER_ID}" \
    --name spark-pi-hello-world \
    --execution-role-arn "${ROLE_ARN}" \
    --release-label "${RELEASE_LABEL}" \
    --job-driver '{
      "sparkSubmitJobDriver": {
        "entryPoint": "local:///usr/lib/spark/examples/src/main/python/pi.py",
        "entryPointArguments": ["100"],
        "sparkSubmitParameters": "--conf spark.executor.instances=1 --conf spark.executor.cores=1 --conf spark.executor.memory=2G --conf spark.driver.cores=1 --conf spark.driver.memory=2G"
      }
    }' \
    --configuration-overrides "{
      \"monitoringConfiguration\": {
        \"cloudWatchMonitoringConfiguration\": {
          \"logGroupName\": \"${LOG_GROUP}\",
          \"logStreamNamePrefix\": \"spark-pi\"
        },
        \"s3MonitoringConfiguration\": {
          \"logUri\": \"s3://${BUCKET_NAME}/logs/\"
        }
      }
    }" \
    --retry-policy-configuration maxAttempts=1 \
    --query id \
    --output text
)"

printf '%s\n' "${VIRTUAL_CLUSTER_ID}" >"${ROOT_DIR}/.lab/virtual-cluster-id"
printf '%s\n' "${JOB_ID}" >"${ROOT_DIR}/.lab/job-run-id"
printf '%s\n' "${RELEASE_LABEL}" >"${ROOT_DIR}/.lab/release-label"

echo "Submitted job ${JOB_ID} using ${RELEASE_LABEL}."
echo "Waiting for a terminal state..."

while true; do
  STATE="$(
    aws emr-containers describe-job-run \
      --virtual-cluster-id "${VIRTUAL_CLUSTER_ID}" \
      --id "${JOB_ID}" \
      --query 'jobRun.state' \
      --output text
  )"
  echo "$(date '+%H:%M:%S') ${STATE}"

  case "${STATE}" in
    COMPLETED)
      break
      ;;
    FAILED|CANCELLED|CANCEL_PENDING)
      aws emr-containers describe-job-run \
        --virtual-cluster-id "${VIRTUAL_CLUSTER_ID}" \
        --id "${JOB_ID}" \
        --query 'jobRun.{state:state,stateDetails:stateDetails,failureReason:failureReason}' \
        --output json
      exit 1
      ;;
  esac
  sleep 20
done

echo
echo "Spark version and Pi result from CloudWatch Logs:"
aws logs filter-log-events \
  --log-group-name "${LOG_GROUP}" \
  --log-stream-name-prefix "spark-pi/${VIRTUAL_CLUSTER_ID}/jobs/${JOB_ID}" \
  --query "events[?contains(message, 'version') || contains(message, 'Pi is roughly')].message" \
  --output text || true

echo
echo "Completed job:"
aws emr-containers describe-job-run \
  --virtual-cluster-id "${VIRTUAL_CLUSTER_ID}" \
  --id "${JOB_ID}" \
  --query 'jobRun.{id:id,name:name,state:state,releaseLabel:releaseLabel,createdAt:createdAt,finishedAt:finishedAt}' \
  --output table

echo
echo "Virtual cluster:"
aws emr-containers describe-virtual-cluster \
  --id "${VIRTUAL_CLUSTER_ID}" \
  --query 'virtualCluster.{id:id,name:name,state:state,eksCluster:containerProvider.id,namespace:containerProvider.info.eksInfo.namespace}' \
  --output table
