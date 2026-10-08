# Teardown: stop all lab charges

Run teardown when you finish the lab. Deleting only the EMR job or virtual
cluster does **not** stop EKS control-plane and EC2 node charges.

## Automated teardown

From this repository:

```bash
export AWS_PROFILE=dev
export AWS_REGION=us-east-1
# Optional: scripts default to emr-on-eks-lab-$ACCOUNT_ID from sts
export ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
bash scripts/teardown.sh
```

The script cancels active jobs and then deletes resources in this order:

1. EMR virtual cluster `emr-eks-lab-vc`
2. EKS cluster `emr-eks-lab` and managed node group `emr-workers`
3. IAM role `EMRContainers-JobExecutionRole`
4. S3 bucket `emr-on-eks-lab-$ACCOUNT_ID`, including its log objects
5. CloudWatch log group `/emr-on-eks/lab`

EKS deletion can take 10–20 minutes. The existing default VPC and its default
subnets are not deleted. The AWS-managed
`AWSServiceRoleForAmazonEMRContainers` service-linked role may remain; the
role itself does not incur a charge.

## Verify deletion

All three commands should return an empty list:

```bash
aws eks list-clusters --output json

aws emr-containers list-virtual-clusters \
  --states RUNNING SUBMITTED BOOTSTRAPPING ARRESTED \
  --output json

aws ec2 describe-instances \
  --filters \
    Name=tag:eks:cluster-name,Values=emr-eks-lab \
    Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[].Instances[].InstanceId' \
  --output json
```

Also verify the lab bucket and log group are gone:

```bash
aws s3api head-bucket \
  --bucket emr-on-eks-lab-$ACCOUNT_ID
# Expected: a Not Found error.

aws logs describe-log-groups \
  --log-group-name-prefix /emr-on-eks/lab \
  --query 'logGroups[].logGroupName'
# Expected: [].
```

## Manual recovery

If automated teardown stops because a resource is already missing, run the
remaining cleanup directly:

```bash
export AWS_PROFILE=dev
export AWS_REGION=us-east-1
export ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

eksctl delete cluster \
  --name emr-eks-lab \
  --region us-east-1 \
  --wait

aws iam delete-role-policy \
  --role-name EMRContainers-JobExecutionRole \
  --policy-name EMRContainersJobExecutionPolicy

aws iam delete-role \
  --role-name EMRContainers-JobExecutionRole

aws s3 rm s3://emr-on-eks-lab-$ACCOUNT_ID --recursive
aws s3api delete-bucket --bucket emr-on-eks-lab-$ACCOUNT_ID

aws logs delete-log-group --log-group-name /emr-on-eks/lab
```
