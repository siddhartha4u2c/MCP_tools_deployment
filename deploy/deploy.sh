#!/usr/bin/env bash
# Deploys the MCP server to AWS ECS Fargate (one small container with a public IP).
# Run from the mcp-demo folder in Git Bash:   bash deploy/deploy.sh
# Prerequisites: Docker Desktop running, AWS CLI configured (aws configure).
set -euo pipefail
export MSYS_NO_PATHCONV=1   # stop Git Bash rewriting "/ecs/..." into Windows paths

APP=mcp-demo
REGION=$(aws configure get region)
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REPO_URI=$ACCOUNT.dkr.ecr.$REGION.amazonaws.com/$APP
EXEC_ROLE=${APP}-task-execution-role
PARAM_NAME=/$APP/api-key

echo "== 1. Container registry (ECR): create repo, build image, push =="
aws ecr describe-repositories --repository-names $APP >/dev/null 2>&1 \
  || aws ecr create-repository --repository-name $APP >/dev/null
aws ecr get-login-password | docker login --username AWS --password-stdin "$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"
docker build --platform linux/amd64 -t $APP .
docker tag $APP:latest $REPO_URI:latest
docker push $REPO_URI:latest

echo "== 2. Secret: store the API key in SSM Parameter Store (encrypted) =="
if ! aws ssm get-parameter --name $PARAM_NAME >/dev/null 2>&1; then
  aws ssm put-parameter --name $PARAM_NAME --type SecureString \
    --value "$(python -c 'import secrets; print(secrets.token_urlsafe(32))')" >/dev/null
fi
PARAM_ARN=arn:aws:ssm:$REGION:$ACCOUNT:parameter$PARAM_NAME

echo "== 3. IAM role ECS uses to pull the image, write logs and read the secret =="
if ! aws iam get-role --role-name $EXEC_ROLE >/dev/null 2>&1; then
  aws iam create-role --role-name $EXEC_ROLE --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{"Effect": "Allow", "Principal": {"Service": "ecs-tasks.amazonaws.com"}, "Action": "sts:AssumeRole"}]
  }' >/dev/null
  aws iam attach-role-policy --role-name $EXEC_ROLE \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
  aws iam put-role-policy --role-name $EXEC_ROLE --policy-name read-api-key --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{\"Effect\": \"Allow\", \"Action\": \"ssm:GetParameters\", \"Resource\": \"$PARAM_ARN\"}]
  }"
  echo "Waiting for the new role to propagate..."; sleep 15
fi

echo "== 4. Logs: CloudWatch log group =="
aws logs create-log-group --log-group-name /ecs/$APP 2>/dev/null || true

echo "== 5. Task definition: what container to run, with how much CPU/memory =="
aws ecs register-task-definition --cli-input-json "{
  \"family\": \"$APP\",
  \"requiresCompatibilities\": [\"FARGATE\"],
  \"networkMode\": \"awsvpc\",
  \"cpu\": \"256\",
  \"memory\": \"512\",
  \"executionRoleArn\": \"arn:aws:iam::$ACCOUNT:role/$EXEC_ROLE\",
  \"containerDefinitions\": [{
    \"name\": \"$APP\",
    \"image\": \"$REPO_URI:latest\",
    \"essential\": true,
    \"portMappings\": [{\"containerPort\": 8000, \"protocol\": \"tcp\"}],
    \"secrets\": [{\"name\": \"MCP_API_KEY\", \"valueFrom\": \"$PARAM_ARN\"}],
    \"logConfiguration\": {\"logDriver\": \"awslogs\", \"options\": {
      \"awslogs-group\": \"/ecs/$APP\", \"awslogs-region\": \"$REGION\", \"awslogs-stream-prefix\": \"ecs\"}}
  }]
}" >/dev/null

echo "== 6. Network: default VPC, public subnets, firewall allowing port 8000 =="
VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
SUBNETS=$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID Name=default-for-az,Values=true \
  --query 'Subnets[].SubnetId' --output text | tr '\t' ',')
SG_ID=$(aws ec2 describe-security-groups --filters Name=group-name,Values=$APP-sg Name=vpc-id,Values=$VPC_ID \
  --query 'SecurityGroups[0].GroupId' --output text)
if [ "$SG_ID" = "None" ]; then
  SG_ID=$(aws ec2 create-security-group --group-name $APP-sg --description "MCP demo port 8000" \
    --vpc-id $VPC_ID --query GroupId --output text)
  # Only your current public IP may connect
  MY_IP=$(curl -s https://checkip.amazonaws.com)
  aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 8000 --cidr $MY_IP/32 >/dev/null
fi

echo "== 7. Cluster + service: keep one copy of the container running =="
aws ecs create-cluster --cluster-name $APP >/dev/null
if aws ecs describe-services --cluster $APP --services $APP --query 'services[?status==`ACTIVE`]' --output text | grep -q .; then
  aws ecs update-service --cluster $APP --service $APP --task-definition $APP --force-new-deployment >/dev/null
else
  aws ecs create-service --cluster $APP --service-name $APP --task-definition $APP \
    --desired-count 1 --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$SG_ID],assignPublicIp=ENABLED}" >/dev/null
fi

echo "== 8. Waiting for the container to start (1-3 minutes)... =="
aws ecs wait services-stable --cluster $APP --services $APP
TASK_ARN=$(aws ecs list-tasks --cluster $APP --service-name $APP --query 'taskArns[0]' --output text)
ENI_ID=$(aws ecs describe-tasks --cluster $APP --tasks $TASK_ARN \
  --query "tasks[0].attachments[0].details[?name=='networkInterfaceId'].value" --output text)
PUBLIC_IP=$(aws ec2 describe-network-interfaces --network-interface-ids $ENI_ID \
  --query 'NetworkInterfaces[0].Association.PublicIp' --output text)

echo
echo "Deployed. Health check:  curl http://$PUBLIC_IP:8000/health"
echo "Run the client:"
echo "  export MCP_API_KEY=\$(aws ssm get-parameter --name $PARAM_NAME --with-decryption --query Parameter.Value --output text)"
echo "  python client.py http://$PUBLIC_IP:8000/mcp"
