# EMR on EKS manual runbook

This runbook shows every step and command manually. It does not use the shell
scripts in `scripts/`.

> Important: the lab resources currently exist. Do not repeat the creation
> steps until the existing lab has been deleted.

## 1. Set the AWS profile and Region

Run these commands in the terminal:

```bash
export AWS_PROFILE=dev
export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION=us-east-1
export ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
```

Confirm which AWS identity will be used:

```bash
aws sts get-caller-identity
```

Use your own 12-digit account ID. Docs and IAM examples use `$ACCOUNT_ID`; fill VPC/subnet placeholders in `cluster.yaml` with yours. Scripts resolve account/bucket via STS automatically.

Check that the required tools are installed:

```bash
aws --version
kubectl version --client
eksctl version
```

If `eksctl` is missing:

```bash
brew install eksctl
```

## 2. Create the EKS configuration

Create a file named `cluster.yaml` with this content:

```yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: emr-eks-lab
  region: us-east-1
  version: "1.31"

# Replace with your VPC / public subnet IDs.
vpc:
  id: vpc-XXXXXXXXXXXXXXXXX
  subnets:
    public:
      us-east-1a:
        id: subnet-XXXXXXXXXXXXXXXXX
      us-east-1b:
        id: subnet-YYYYYYYYYYYYYYYYY
  clusterEndpoints:
    publicAccess: true
    privateAccess: false

accessConfig:
  authenticationMode: API_AND_CONFIG_MAP

iam:
  withOIDC: true

managedNodeGroups:
  - name: emr-workers
    instanceType: m5.xlarge
    desiredCapacity: 1
    minSize: 1
    maxSize: 1
    volumeSize: 20
    privateNetworking: false
    labels:
      workload: emr
    tags:
      Project: emr-on-eks-lab
      Environment: lab
```

This configuration creates:

- EKS cluster `emr-eks-lab`
- Kubernetes version `1.31`
- one managed node group named `emr-workers`
- one `m5.xlarge` EC2 node
- no Cluster Autoscaler and no Karpenter
- an IAM OIDC provider for Spark job roles
- no NAT gateway

The EKS control plane uses two public subnets in the existing default VPC.

## 3. Create the EKS cluster

Run:

```bash
eksctl create cluster --config-file cluster.yaml
```

This normally takes 15–25 minutes.

`eksctl` reads `cluster.yaml`, generates CloudFormation templates internally,
and submits CloudFormation stacks to AWS.

Check the EKS cluster:

```bash
aws eks describe-cluster \
  --name emr-eks-lab \
  --query 'cluster.{name:name,status:status,version:version}' \
  --output table
```

Check the managed node group:

```bash
eksctl get nodegroup \
  --cluster emr-eks-lab \
  --region us-east-1
```

The cluster and node group should both become `ACTIVE`.

## 4. Connect kubectl to EKS

Add the cluster to the local Kubernetes configuration:

```bash
aws eks update-kubeconfig \
  --name emr-eks-lab \
  --region us-east-1
```

Confirm that the EC2 worker joined Kubernetes:

```bash
kubectl get nodes
```

The node should have status `Ready`.

## 5. Create a Kubernetes namespace

Create namespace `emr-eks`:

```bash
kubectl create namespace emr-eks
```

Verify it:

```bash
kubectl get namespace emr-eks
```

Spark driver and executor pods will run inside this namespace.

## 6. Grant Amazon EMR access to the namespace

Create the EMR Kubernetes role, role binding, and IAM identity mapping:

```bash
eksctl create iamidentitymapping \
  --cluster emr-eks-lab \
  --region us-east-1 \
  --namespace emr-eks \
  --service-name emr-containers
```

Verify the Kubernetes permissions:

```bash
kubectl get role,rolebinding -n emr-eks
```

You should see a role and role binding named `emr-containers`.

## 7. Create the S3 and CloudWatch logging destinations

Create an S3 bucket:

```bash
aws s3api create-bucket \
  --bucket emr-on-eks-lab-$ACCOUNT_ID
```

Create a CloudWatch log group:

```bash
aws logs create-log-group \
  --log-group-name /emr-on-eks/lab
```

## 8. Create the Spark job IAM policy

Create `iam/job-execution-trust.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "InitialEMRContainersTrust",
      "Effect": "Allow",
      "Principal": {
        "Service": "emr-containers.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

Create `iam/job-execution-policy.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadEMRSamples",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::us-east-1.elasticmapreduce",
        "arn:aws:s3:::us-east-1.elasticmapreduce/*"
      ]
    },
    {
      "Sid": "UseLabBucket",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::emr-on-eks-lab-$ACCOUNT_ID",
        "arn:aws:s3:::emr-on-eks-lab-$ACCOUNT_ID/*"
      ]
    },
    {
      "Sid": "DescribeCloudWatchLogs",
      "Effect": "Allow",
      "Action": [
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ],
      "Resource": "*"
    },
    {
      "Sid": "WriteLabLogs",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:us-east-1:$ACCOUNT_ID:log-group:/emr-on-eks/lab:*"
    }
  ]
}
```

## 9. Create the Spark job execution role

Create the IAM role:

```bash
aws iam create-role \
  --role-name EMRContainers-JobExecutionRole \
  --assume-role-policy-document file://iam/job-execution-trust.json
```

Attach the inline IAM policy:

```bash
aws iam put-role-policy \
  --role-name EMRContainers-JobExecutionRole \
  --policy-name EMRContainersJobExecutionPolicy \
  --policy-document file://iam/job-execution-policy.json
```

Update the role trust policy for the EKS OIDC provider and namespace:

```bash
aws emr-containers update-role-trust-policy \
  --cluster-name emr-eks-lab \
  --namespace emr-eks \
  --role-name EMRContainers-JobExecutionRole
```

This allows EMR-managed Kubernetes service accounts in namespace `emr-eks`
to assume the role.

Get the role ARN:

```bash
ROLE_ARN=$(aws iam get-role \
  --role-name EMRContainers-JobExecutionRole \
  --query 'Role.Arn' \
  --output text)

echo "$ROLE_ARN"
```

## 10. Create the EMR virtual cluster

Register EKS cluster `emr-eks-lab` and namespace `emr-eks` with Amazon EMR:

```bash
aws emr-containers create-virtual-cluster \
  --name emr-eks-lab-vc \
  --container-provider '{
    "id": "emr-eks-lab",
    "type": "EKS",
    "info": {
      "eksInfo": {
        "namespace": "emr-eks"
      }
    }
  }'
```

The `id` value must exactly match the EKS cluster name. The `namespace`
value must exactly match the Kubernetes namespace.

Get the virtual cluster ID:

```bash
VC_ID=$(aws emr-containers list-virtual-clusters \
  --states RUNNING \
  --query "virtualClusters[?name=='emr-eks-lab-vc'].id | [0]" \
  --output text)

echo "$VC_ID"
```

## 11. Submit the Spark Pi job

Submit a job using EMR `7.10.0`, which contains Spark `3.5.5-amzn-1`:

```bash
JOB_ID=$(aws emr-containers start-job-run \
  --virtual-cluster-id "$VC_ID" \
  --name spark-pi-hello-world \
  --execution-role-arn "$ROLE_ARN" \
  --release-label emr-7.10.0-latest \
  --job-driver '{
    "sparkSubmitJobDriver": {
      "entryPoint": "local:///usr/lib/spark/examples/src/main/python/pi.py",
      "entryPointArguments": ["100"],
      "sparkSubmitParameters": "--conf spark.executor.instances=1 --conf spark.executor.cores=1 --conf spark.executor.memory=2G --conf spark.driver.cores=1 --conf spark.driver.memory=2G"
    }
  }' \
  --configuration-overrides '{
    "monitoringConfiguration": {
      "cloudWatchMonitoringConfiguration": {
        "logGroupName": "/emr-on-eks/lab",
        "logStreamNamePrefix": "spark-pi"
      },
      "s3MonitoringConfiguration": {
        "logUri": "s3://emr-on-eks-lab-$ACCOUNT_ID/logs/"
      }
    }
  }' \
  --retry-policy-configuration maxAttempts=1 \
  --query id \
  --output text)

echo "$JOB_ID"
```

## 11A. Submit Spark 4 Iceberg VARIANT on regular S3

This job uses the same EKS cluster and virtual cluster. It does not use
Amazon S3 Tables. Iceberg metadata and data files are written to the regular
bucket:

```text
s3://emr-on-eks-lab-$ACCOUNT_ID/warehouse/
```

The Spark catalog name in the script is `lab`. The table is `lab.test.users`.

`emr-spark-8.0.0-latest` selects Spark 4.0.2. The job adds this Iceberg jar:

```text
org.apache.iceberg:iceberg-spark-runtime-4.0_2.13:1.10.0
```

Download that jar and upload it to the lab bucket:

```bash
curl -L -o iceberg-spark-runtime-4.0_2.13-1.10.0.jar \
  https://repo1.maven.org/maven2/org/apache/iceberg/iceberg-spark-runtime-4.0_2.13/1.10.0/iceberg-spark-runtime-4.0_2.13-1.10.0.jar

aws s3 cp iceberg-spark-runtime-4.0_2.13-1.10.0.jar \
  s3://emr-on-eks-lab-$ACCOUNT_ID/jars/iceberg-spark-runtime-4.0_2.13-1.10.0.jar

aws s3 cp scripts/iceberg_variant_users.py \
  s3://emr-on-eks-lab-$ACCOUNT_ID/scripts/iceberg_variant_users.py
```

Submit the PySpark script:

```bash
JOB_ID=$(aws emr-containers start-job-run \
  --virtual-cluster-id "$VC_ID" \
  --name spark4-iceberg-variant \
  --execution-role-arn "$ROLE_ARN" \
  --release-label emr-spark-8.0.0-latest \
  --job-driver '{
    "sparkSubmitJobDriver": {
      "entryPoint": "s3://emr-on-eks-lab-$ACCOUNT_ID/scripts/iceberg_variant_users.py",
      "sparkSubmitParameters": "--jars s3://emr-on-eks-lab-$ACCOUNT_ID/jars/iceberg-spark-runtime-4.0_2.13-1.10.0.jar --conf spark.sql.extensions=org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions --conf spark.sql.catalog.lab=org.apache.iceberg.spark.SparkCatalog --conf spark.sql.catalog.lab.type=hadoop --conf spark.sql.catalog.lab.warehouse=s3a://emr-on-eks-lab-$ACCOUNT_ID/warehouse --conf spark.sql.catalog.lab.io-impl=org.apache.iceberg.aws.s3.S3FileIO --conf spark.sql.catalog.lab.client.region=us-east-1 --conf spark.executor.instances=1 --conf spark.executor.cores=1 --conf spark.executor.memory=2G --conf spark.driver.cores=1 --conf spark.driver.memory=2G"
    }
  }' \
  --configuration-overrides '{
    "monitoringConfiguration": {
      "cloudWatchMonitoringConfiguration": {
        "logGroupName": "/emr-on-eks/lab",
        "logStreamNamePrefix": "spark4-iceberg"
      },
      "s3MonitoringConfiguration": {
        "logUri": "s3://emr-on-eks-lab-$ACCOUNT_ID/logs/"
      }
    }
  }' \
  --retry-policy-configuration maxAttempts=1 \
  --query id \
  --output text)

echo "$JOB_ID"
```

The driver log should contain `SPARK_VERSION 4.0.2-amzn-0` and three
`USER_ROW` lines. Deleting the lab bucket in the teardown section also
deletes this Iceberg warehouse.

## 12. Watch the job

Check the EMR job state:

```bash
aws emr-containers describe-job-run \
  --virtual-cluster-id "$VC_ID" \
  --id "$JOB_ID" \
  --query 'jobRun.{name:name,state:state,details:stateDetails,release:releaseLabel}' \
  --output table
```

Watch the Kubernetes pods:

```bash
kubectl get pods -n emr-eks
```

For continuous updates:

```bash
kubectl get pods -n emr-eks -w
```

Inspect pod events:

```bash
kubectl get events \
  -n emr-eks \
  --sort-by=.lastTimestamp
```

## 13. Read logs

List CloudWatch log streams:

```bash
aws logs describe-log-streams \
  --log-group-name /emr-on-eks/lab \
  --query 'logStreams[].logStreamName'
```

Read recent CloudWatch logs:

```bash
aws logs tail /emr-on-eks/lab --since 10m
```

List S3 logs:

```bash
aws s3 ls \
  s3://emr-on-eks-lab-$ACCOUNT_ID/logs/ \
  --recursive
```

The successful driver output contains:

```text
Pi is roughly 3.153160
```

## 14. Manual teardown

Find and delete the virtual cluster:

```bash
VC_ID=$(aws emr-containers list-virtual-clusters \
  --states RUNNING \
  --query "virtualClusters[?name=='emr-eks-lab-vc'].id | [0]" \
  --output text)

aws emr-containers delete-virtual-cluster \
  --id "$VC_ID"
```

Delete the EKS cluster, EC2 worker, and generated CloudFormation stacks:

```bash
eksctl delete cluster \
  --name emr-eks-lab \
  --region us-east-1 \
  --wait
```

Delete the job role:

```bash
aws iam delete-role-policy \
  --role-name EMRContainers-JobExecutionRole \
  --policy-name EMRContainersJobExecutionPolicy

aws iam delete-role \
  --role-name EMRContainers-JobExecutionRole
```

Empty and delete the S3 bucket:

```bash
aws s3 rm \
  s3://emr-on-eks-lab-$ACCOUNT_ID \
  --recursive

aws s3api delete-bucket \
  --bucket emr-on-eks-lab-$ACCOUNT_ID
```

Delete the CloudWatch log group:

```bash
aws logs delete-log-group \
  --log-group-name /emr-on-eks/lab
```

The existing default VPC and default subnets are not deleted.
