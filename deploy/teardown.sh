#!/usr/bin/env bash
# Deletes everything deploy.sh created, so you stop paying for it.
# Run from the mcp-demo folder in Git Bash:   bash deploy/teardown.sh
set -uo pipefail
export MSYS_NO_PATHCONV=1

APP=mcp-demo

echo "Stopping service and deleting cluster..."
aws ecs update-service --cluster $APP --service $APP --desired-count 0 >/dev/null 2>&1
aws ecs delete-service --cluster $APP --service $APP --force >/dev/null 2>&1
aws ecs wait services-inactive --cluster $APP --services $APP 2>/dev/null
aws ecs delete-cluster --cluster $APP >/dev/null 2>&1

echo "Deregistering task definitions..."
for TD in $(aws ecs list-task-definitions --family-prefix $APP --query 'taskDefinitionArns[]' --output text); do
  aws ecs deregister-task-definition --task-definition $TD >/dev/null
done

echo "Deleting security group (retries while the network interface is released)..."
VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
SG_ID=$(aws ec2 describe-security-groups --filters Name=group-name,Values=$APP-sg Name=vpc-id,Values=$VPC_ID \
  --query 'SecurityGroups[0].GroupId' --output text)
if [ "$SG_ID" != "None" ]; then
  for i in 1 2 3 4 5 6; do aws ec2 delete-security-group --group-id $SG_ID 2>/dev/null && break; sleep 10; done
fi

echo "Deleting image repository, secret, logs and IAM role..."
aws ecr delete-repository --repository-name $APP --force >/dev/null 2>&1
aws ssm delete-parameter --name /$APP/api-key 2>/dev/null
aws logs delete-log-group --log-group-name /ecs/$APP 2>/dev/null
aws iam delete-role-policy --role-name $APP-task-execution-role --policy-name read-api-key 2>/dev/null
aws iam detach-role-policy --role-name $APP-task-execution-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy 2>/dev/null
aws iam delete-role --role-name $APP-task-execution-role 2>/dev/null

echo "Done. All mcp-demo resources removed."
