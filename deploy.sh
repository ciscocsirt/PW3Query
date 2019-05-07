#!/bin/bash

APIKEY="<yourkey>"
AWS_PROFILE=
AWS_REGION=
STACK_NAME=PW3Query


if [ "$AWS_REGION" != "" ]
then
  AWS_REGION_STR="--region ${AWS_REGION}"
else
  AWS_REGION_STR=""
fi

if [ "$AWS_PROFILE" != "" ]
then
  AWS_PROFILE_STR="--profile ${AWS_PROFILE}"
else
  AWS_PROFILE_STR=""
fi

FIRST_RUN=0
BUCKET_NAME="$(aws ${AWS_PROFILE_STR} ${AWS_REGION_STR} s3api list-buckets --query 'Buckets[?starts_with(Name, `pw3query`) == `true`].Name' --output text)"
if [ "$BUCKET_NAME" == "" ]
then
  FIRST_RUN=1
  BUCKET_NAME="pw3query-$(date +%s)-$((1 + RANDOM % 100000))"
fi

INFO=$(tput setaf 3)
FAILURE=$(tput setaf 1)
SUCCESS=$(tput setaf 2)
WARNING=$(tput setaf 4)
END=$(tput sgr0)

if [ $FIRST_RUN -eq 1 ]; then
    #################################################################################

    printf "${INFO}Creating S3 Bucket${END}\n"
    printf "${INFO}....Please wait.${END}\n"
    aws ${AWS_PROFILE_STR} ${AWS_REGION_STR} s3 mb s3://${BUCKET_NAME} >> pw3query.log 2>&1

    if [ $? -ne 0 ]
    then
        printf "${FAILURE}....Failed to create ${BUCKET_NAME} S3 Bucket! See pw3query.log for details.${END}\n"
        exit
    else
        printf "${SUCCESS}....Successfully created ${BUCKET_NAME} S3 Bucket!${END}\n"
    fi

    #################################################################################

    printf "${INFO}Updating S3 Bucket ACL Policies${END}\n"
    printf "${INFO}....Please wait.${END}\n"
    aws ${AWS_PROFILE_STR} ${AWS_REGION_STR} s3api put-public-access-block \
      --bucket ${BUCKET_NAME} \
      --public-access-block-configuration '{"BlockPublicAcls":true,"IgnorePublicAcls":true,"BlockPublicPolicy":true,"RestrictPublicBuckets":true}' >> pw3query.log 2>&1

    if [ $? -ne 0 ]
    then
        printf "${FAILURE}....Failed to update S3 Bucket ACLs! See pw3query.log for details.${END}\n"
        exit
    else
        printf "${SUCCESS}....Successfully updated S3 Bucket ACLs!${END}\n"
    fi

    #################################################################################

    printf "${INFO}Updating S3 LifeCycle Policy${END}\n"
    printf "${INFO}....Please wait.${END}\n"
    #3 Create 30 day expiration for results
    aws ${AWS_PROFILE_STR} ${AWS_REGION_STR} s3api put-bucket-lifecycle \
        --bucket ${BUCKET_NAME}  \
        --lifecycle-configuration '{"Rules":[{"ID":"PurgeAfter30Days","Prefix":"results/","Status":"Enabled","Expiration":{"Days":30}}]}' >> pw3query.log 2>&1
    if [ $? -ne 0 ]
    then
        printf "${FAILURE}....Failed to add S3 Bucket LifeCycle Policy! See pw3query.log for details.${END}\n"
        exit
    else
        printf "${SUCCESS}....Successfully added S3 Bucket LifeCycle Policy!${END}\n"
    fi

    #################################################################################
fi

printf "${INFO}Uploading Query Packs to S3${END}\n"
printf "${INFO}....Please wait.${END}\n"
aws ${AWS_PROFILE_STR} ${AWS_REGION_STR} s3 cp packs/ s3://${BUCKET_NAME}/packs --recursive --exclude '*' --include "*.json" >> pw3query.log 2>&1 
if [ $? -ne 0 ]
then
    printf "${FAILURE}....Failed to upload query packs to S3 Bucket! See pw3query.log for details.${END}\n"
    exit
else
    printf "${SUCCESS}....Successfully uploaded query packs to S3 Bucket!${END}\n"
fi

printf "${INFO}Creating Packaged CloudFormation Template${END}\n"
printf "${INFO}....Please wait.${END}\n"
aws ${AWS_PROFILE_STR} ${AWS_REGION_STR} cloudformation package \
    --template-file template.yaml \
    --s3-bucket ${BUCKET_NAME} \
    --s3-prefix src \
    --output-template-file packaged-template.yaml >> pw3query.log 2>&1
if [ $? -ne 0 ]
then
    printf "${FAILURE}....Failed to create packaged CloudFormation template! See pw3query.log for details.${END}\n"
    exit
else
    printf "${SUCCESS}....Successfully created packaged CloudFormation template!${END}\n"
fi

#################################################################################

printf "${INFO}Deploying AWS CloudFormation Template${END}\n"
printf "${INFO}....Please wait.${END}\n"
aws ${AWS_PROFILE_STR} ${AWS_REGION_STR} cloudformation deploy \
    --stack-name $STACK_NAME \
    --template-file packaged-template.yaml \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides PW3APIPARAM=$APIKEY BUCKETNAME=$BUCKET_NAME >> pw3query.log 2>&1
if [ $? -eq 1 ]
then
    printf "${FAILURE}....Failed to deploy CloudFormation template! See pw3query.log for details.${END}\n"
    exit
else
    printf "${SUCCESS}....Successfully deployed CloudFormation template!${END}\n"
fi

#################################################################################

#6 Add S3 Trigger to the Lambda function via CLI, allowing query pack updates to be automatically processed.
#  NOTE: This is a workaround - CloudFormation does not allow you to reference an existing resource, so the 
#  trigger has to be added here, and should only be added once (otherwise the script will error out).
if [ $FIRST_RUN -eq 0 ]; then
  printf "\n${SUCCESS}....Deployment Complete!${END}\n"
  exit
fi

printf "${INFO}Creating S3 Lambda Trigger${END}\n"

lambda_arn=$(aws ${AWS_PROFILE_STR} ${AWS_REGION_STR} lambda get-function --function-name PW3Query-Dispatch | egrep -o '"FunctionArn":.*?,' | egrep -o ':[[:space:]]*".*' | egrep -o '"[^"]+"'  | egrep -o '[^"]+')
# sed alternative: sed -r 's/.*?"FunctionArn":[[:space:]]*"([^"]+)".*/\1/'

aws ${AWS_PROFILE_STR} ${AWS_REGION_STR} lambda add-permission \
    --function-name "PW3Query-Dispatch"  \
    --action lambda:InvokeFunction \
    --principal s3.amazonaws.com \
    --source-arn arn:aws:s3:::${BUCKET_NAME} \
    --statement-id pw3qS3Trigger >> pw3query.log 2>&1

aws ${AWS_PROFILE_STR} ${AWS_REGION_STR} s3api put-bucket-notification-configuration \
--bucket ${BUCKET_NAME} \
--notification-configuration "{\"LambdaFunctionConfigurations\":[{\"Id\":\"QueryPackUpdateEvent\",\"LambdaFunctionArn\":\"${lambda_arn}\",\"Events\":[\"s3:ObjectCreated:*\"],\"Filter\":{\"Key\":{\"FilterRules\":[{\"Name\":\"prefix\",\"Value\":\"packs\"}]}}}]}" >> pw3query.log 2>&1

if [ $? -ne 0 ]
then
    printf "${FAILURE}....Failed to create s3 trigger! See pw3query.log for details.${END}\n"
    exit
else
    printf "${SUCCESS}....Successfully created s3 trigger!${END}\n"
fi

#################################################################################
printf "${INFO}Generating Access Key${END}\n"
printf "${INFO}....Please wait.${END}\n"

aws ${AWS_PROFILE_STR} ${AWS_REGION_STR} iam create-access-key --user-name PW3QueryUser
if [ $? -ne 0 ]
then
    exit
else
    printf "${SUCCESS}....Successfully created access key for PW3QueryUser!${END}\n"
    printf "${WARNING}Please safely store the SecretAccessKey and AccessKeyID output above. You'll use this key to programmatically access query results stored in S3.${END}\n"
fi
#################################################################################

printf "\n\n${INFO}This appears to be your first time setting up PWQuery - Would you like to go ahead and kick-off a first run of the query packs? If not, queries are scheduled to run every 4 days (which is how often PublicWWW indexes new data).${END}\n"
read -p "y/n: " answer
if [ "$answer" == "Y" ] || [ "$answer" == "y" ]
then
   printf "${INFO}....Please wait.${END}\n"
   aws ${AWS_PROFILE_STR} ${AWS_REGION_STR} lambda invoke --function-name 'PW3Query-Dispatch' - >> pw3query.log 2>&1
   if [ $? -ne 0 ]
   then
       printf "${FAILURE}....Failed to invoke 'PW3Query-Dispatch' lambda function! Please see pw3query.log for details.${END}\n"
       exit
   else
       printf "${SUCCESS}....Successfully dispatched queries to the 'fetch and process' queue!${END}\n"
   fi
fi

printf "\n${SUCCESS}....Deployment Complete!${END}\n"
