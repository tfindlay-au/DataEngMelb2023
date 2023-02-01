#!/usr/bin/env make
include Makehelp

# Backend Configuration
BACKEND_BUCKET = terraform-cmd-demos-backends
BACKEND_KEY = terraform-functional-data-engineering
BACKEND_REGION = ap-southeast-2
BACKEND_PROFILE = cmdlab-sandpit2
BACKEND_DYNAMODB_TABLE = terraform-banking-demo-lock

BACKEND_CONFIG = -backend-config="bucket=${BACKEND_BUCKET}" -backend-config="key=${BACKEND_KEY}/${TERRAFORM_ROOT_MODULE}" -backend-config="region=${BACKEND_REGION}" -backend-config="profile=${BACKEND_PROFILE}" -backend-config="dynamodb_table=${BACKEND_DYNAMODB_TABLE}" -backend-config="encrypt=true"
#BACKEND_CONFIG = -backend-config="bucket=${BACKEND_BUCKET}" -backend-config="key=terraform/backends/service-layer.tfstate" -backend-config="region=${BACKEND_REGION}" -backend-config="profile=${BACKEND_PROFILE}" -backend-config="dynamodb_table=terraform-ds-terraform-lock" -backend-config="encrypt=true"

# Targets
# This init target is only used when first deploying the backend. It should be commented out once the backend exists.
## Initialise Terraform
# init: .env
# 	docker-compose run --rm envvars ensure --tags confluent-init
# 	docker-compose run --rm terraform-utils sh -c 'cd ${TERRAFORM_ROOT_MODULE}; terraform init'
# .PHONY: init

ENV			?= dev
APP_NAME 	?= ea-dp-restproxy-services-ods-dev
ECR_REPO 	?= 216025189467.dkr.ecr.ap-southeast-2.amazonaws.com
VERSION 	?= $(shell git rev-parse HEAD | cut -c 1-7)  #Making image tag as same as commitID also
AWS_PROFILE	?= cmdlab-sandpit2
AWS_REGION 	?= ap-southeast-2
CONTAINER_FOLDER ?= app/kafka
IMAGE_TAG	?= $(shell echo "${VERSION}" | sed 's/ //g')

HTTP_PROXY=http://forwardproxy.awsprod.internal:3128
HTTPS_PROXY=http://forwardproxy.awsprod.internal:3128
NO_PROXY="localhost,127.0.0.1,169.254.169.254,*.dataservices.awsnonprod.internal,*.dataservices.awsprod.internal,*.domain.internal,*.cloudhub.io,*.compute.internal,*.s3.ap-southeast-2.amazonaws.com"

AWS_ROLE_STS=gitlab_runner
AWS_ACCOUNT_ID=354334841216

build-restproxy:
	set -e; \
	cp .npmrc ./${CONTAINER_FOLDER}
	cd ${CONTAINER_FOLDER}; \
	ls -la; \
	npm ci --verbose; \
	npm run build --verbose; \
	npm prune --production;


repo-login:	
	aws ecr get-login-password --region $(AWS_REGION) | docker login --username AWS --password-stdin $(ECR_REPO)

version:
	@echo $(IMAGE_TAG)

local-run:
	npm run start --prefix ./app

build:
	set -e; \
	cd ${CONTAINER_FOLDER}; \
	docker build -t $(APP_NAME) \
	--build-arg "HTTP_PROXY=${HTTP_PROXY}" \
    --build-arg "HTTPS_PROXY=${HTTPS_PROXY}" \
	.

build-nc:
	set -e; \
	cd ${CONTAINER_FOLDER}; \
	docker build --no-cache -t $(APP_NAME) \
	--build-arg "HTTP_PROXY=${HTTP_PROXY}" \
    --build-arg "HTTPS_PROXY=${HTTPS_PROXY}" \
	.

push: repo-login publish-latest publish-version

publish-latest: tag-latest
	@echo 'publish latest to $(ECR_REPO)'
	docker push $(ECR_REPO)/$(APP_NAME):latest

publish-version: tag-version
	@echo 'publish $(IMAGE_TAG) to $(ECR_REPO)'
	docker push $(ECR_REPO)/$(APP_NAME):$(IMAGE_TAG)

tag: tag-latest tag-version

tag-latest:
	@echo 'create tag latest'
	docker tag $(APP_NAME) $(ECR_REPO)/$(APP_NAME):latest

tag-version:
	@echo 'create tag $(IMAGE_TAG)'
	docker tag $(APP_NAME) $(ECR_REPO)/$(APP_NAME):$(IMAGE_TAG)

layers:
	docker-compose run --rm lambda sh -c 'cd ${TERRAFORM_ROOT_MODULE}/lambda_layers/src && pip install -r requirements.txt -t python/lib/python3.9/site-packages/'
.PHONY: layers

load:
	docker-compose run --rm terraform-utils sh -c 'cd ${TERRAFORM_ROOT_MODULE}; cp config/locals.yaml scripts/firehose_transform'
.PHONY: load

glue:
	docker-compose run --rm awscli sh -c 'aws glue start-job-run --job-name kinesis-flink-test-app-glue-stream-job --profile cmdlab-sandpit2 --region ap-southeast-2'
.PHONY: glue

startWorkflows:
	docker-compose run --rm awscli sh -c 'aws glue start-workflow-run --name functional-data-engineering-nonprod-customer-workflow --run-properties WORKFLOW_RUN_ITERATION=${RUN_ITERATION} --profile cmdlab-sandpit2 --region ap-southeast-2'
	docker-compose run --rm awscli sh -c 'aws glue start-workflow-run --name functional-data-engineering-nonprod-transactions-workflow --run-properties WORKFLOW_RUN_ITERATION=${RUN_ITERATION} --profile cmdlab-sandpit2 --region ap-southeast-2'
.PHONY: startWorkflows

graph:
	docker-compose run --rm terraform-utils sh -c 'apk update && apk add ca-certificates graphviz ;cd ${TERRAFORM_ROOT_MODULE}; terraform graph | dot -Tpng > graph.png'
.PHONY: graph

manualData:
	docker-compose run --rm awscli sh -c 'aws s3 cp ./infra/manual_data/t_2.csv s3://functional-data-engineering-nonprod-datalake-bucket/datalake/landing/transactions/ --profile cmdlab-sandpit2 --region ap-southeast-2'
	docker-compose run --rm awscli sh -c 'aws s3 cp ./infra/manual_data/c_2.csv s3://functional-data-engineering-nonprod-datalake-bucket/datalake/landing/customer/ --profile cmdlab-sandpit2 --region ap-southeast-2'
.PHONY: manualData

## Force update ECS service
forceUpdate: .env
	docker-compose run --rm envvars ensure --tags ecs
	docker-compose run --rm awscli sh -c 'aws ecs update-service --force-new-deployment --service  ${ECS_SERVICE}-0 --cluster ${ECS_CLUSTER} --profile data_services'
	docker-compose run --rm awscli sh -c 'aws ecs update-service --force-new-deployment --service  ${ECS_SERVICE}-1 --cluster ${ECS_CLUSTER} --profile data_services'
	docker-compose run --rm awscli sh -c 'aws ecs update-service --force-new-deployment --service  ${ECS_SERVICE}-2 --cluster ${ECS_CLUSTER} --profile data_services'
.PHONY: forceUpdate

profile:
	docker-compose run --rm awscli sh -c 'aws configure list'
	docker-compose run --rm awscli sh -c 'aws configure set profile.cmdlab-sandpit2.role_arn arn:aws:iam::${AWS_ACCOUNT_ID}:role/${AWS_ROLE_STS}'
	docker-compose run --rm awscli sh -c 'aws configure set profile.cmdlab-sandpit2.credential_source Ec2InstanceMetadata'
.PHONY: profile

password:
	docker-compose run --rm awscli sh -c 'aws redshift-serverless update-namespace --namespace-name functional-data-engineering-nonprod-namespace --admin-username awsuser --admin-user-password ${REDSHIFT_PASSWORD} --profile ${AWS_PROFILE} --region ${AWS_REGION}'
.PHONY: password


## Initialise Terraform
init: .env 
	docker-compose run --rm envvars ensure --tags confluent	
	docker-compose run --rm terraform-utils sh -c 'cd ${TERRAFORM_ROOT_MODULE}; terraform init ${BACKEND_CONFIG}'
.PHONY: init

## Initialise Terraform but also upgrade modules/providers
upgrade: .env
	docker-compose run --rm envvars ensure --tags confluent-init
	docker-compose run --rm terraform-utils sh -c 'cd ${TERRAFORM_ROOT_MODULE}; terraform init -upgrade -upgrade ${BACKEND_CONFIG}'
.PHONY: upgrade

## Generate a plan
plan: .env init workspace
	docker-compose run --rm envvars ensure --tags confluent
	docker-compose run --rm terraform-utils sh -c 'cd ${TERRAFORM_ROOT_MODULE}; terraform plan'
.PHONY: plan

## Generate a plan and save it to the root of the repository. This should be used by CICD systems
planAuto: .env init workspace
	docker-compose run --rm envvars ensure --tags confluent
	docker-compose run --rm terraform-utils sh -c 'cd ${TERRAFORM_ROOT_MODULE}; terraform plan -out ../${TERRAFORM_ROOT_MODULE}-${TERRAFORM_WORKSPACE}.tfplan'
.PHONY: planAuto

## Generate a plan and apply it
apply: .env format validate init workspace
	docker-compose run --rm envvars ensure --tags confluent
	docker-compose run --rm terraform-utils sh -c 'cd ${TERRAFORM_ROOT_MODULE}; terraform apply'
.PHONY: apply

## Apply the plan generated by planAuto. This should be used by CICD systems
applyAuto: .env init workspace planAuto
	docker-compose run --rm envvars ensure --tags confluent
	docker-compose run --rm terraform-utils sh -c 'cd ${TERRAFORM_ROOT_MODULE}; terraform apply -auto-approve ../${TERRAFORM_ROOT_MODULE}-${TERRAFORM_WORKSPACE}.tfplan'
.PHONY: applyAuto

## Apply the plan generated by planAuto. This should be used by CICD systems
applyAutoNoPlan: .env init workspace layers load
	docker-compose run --rm envvars ensure --tags confluent
	docker-compose run --rm terraform-utils sh -c 'cd ${TERRAFORM_ROOT_MODULE}; terraform apply -auto-approve'
	docker-compose run --rm awscli sh -c 'aws glue start-job-run --job-name kinesis-flink-test-app-glue-stream-job --profile cmdlab-sandpit2 --region ap-southeast-2'
.PHONY: applyAutoNoPlan

## Destroy resources
destroyPlan: .env init workspace
	docker-compose run --rm envvars ensure --tags confluent
	docker-compose run --rm terraform-utils sh -c 'cd ${TERRAFORM_ROOT_MODULE}; terraform plan -destroy -var="image_tag=${IMAGE_TAG}"'
.PHONY: destroyPlan

## Destroy resources
destroy: .env init workspace
	docker-compose run --rm envvars ensure --tags confluent
	docker-compose run --rm terraform-utils sh -c 'cd ${TERRAFORM_ROOT_MODULE}; terraform destroy'
.PHONY: destroy

import: .env init workspace
	docker-compose run --rm envvars ensure --tags confluent
	docker-compose run --rm terraform-utils sh -c 'cd ${TERRAFORM_ROOT_MODULE}; terraform import aws_appflow_flow.ga arn:aws:appflow:ap-southeast-2:354334841216:flow/test7'
.PHONY: import

## Destroy resources
destroyAuto: .env init workspace
	docker-compose run --rm envvars ensure --tags confluent
	docker-compose run --rm terraform-utils sh -c 'cd ${TERRAFORM_ROOT_MODULE}; terraform destroy -auto-approve'
.PHONY: destroyAuto

## Show the statefile
show: .env init workspace
	docker-compose run --rm envvars ensure --tags confluent
	docker-compose run --rm terraform-utils sh -c 'cd ${TERRAFORM_ROOT_MODULE}; terraform show -no-color > output.json'
.PHONY: show

## Show the statefile
stateShow: .env init workspace
	docker-compose run --rm envvars ensure --tags confluent
	docker-compose run --rm terraform-utils sh -c 'cd ${TERRAFORM_ROOT_MODULE}; terraform state show aws_appflow_flow.ga'
.PHONY: stateShow

## Show root module outputs
output: .env init workspace
	docker-compose run --rm envvars ensure --tags confluent
	docker-compose run --rm terraform-utils sh -c 'cd ${TERRAFORM_ROOT_MODULE}; terraform output'
.PHONY: output

## Switch to specified workspace
workspace: .env
	docker-compose run --rm envvars ensure --tags confluent
	docker-compose run --rm terraform-utils sh -c 'cd $(TERRAFORM_ROOT_MODULE); terraform workspace select $(TERRAFORM_WORKSPACE) || terraform workspace new $(TERRAFORM_WORKSPACE)'
.PHONY: workspace

## Validate terraform is syntactically correct
validate: .env init
	docker-compose run --rm envvars ensure --tags confluent
	docker-compose run --rm terraform-utils sh -c 'cd ${TERRAFORM_ROOT_MODULE}; terraform validate'
.PHONY: validate

## Format all Terraform files
format: .env
	docker-compose run --rm terraform-utils terraform fmt -diff -recursive
.PHONY: format

## Interacticely launch a shell in the Terraform docker container
shell: .env
	docker-compose run --rm terraform-utils sh
.PHONY: shell

unlock: .env
	docker-compose run --rm envvars ensure --tags confluent
	docker-compose run --rm terraform-utils sh -c 'cd ${TERRAFORM_ROOT_MODULE}; terraform force-unlock ${LOCK_ID}'
.PHONY: unlock

## Generate Docker env file
.env:
	touch .env
	docker-compose run --rm envvars validate
	docker-compose run --rm envvars envfile --overwrite
.PHONY: .env

gen: .env
	docker-compose run --rm python sh -c 'python3 producer.py'
.PHONY: gen


