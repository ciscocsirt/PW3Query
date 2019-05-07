import boto3
import time
import json
import sys
import os

s3 = boto3.client('s3')
sqs = boto3.resource('sqs')
BUCKET_PREFIX="packs/"

SQS_QUEUE_NAME='PW3Query-Queue.fifo'
sqs_queue = sqs.get_queue_by_name(QueueName=SQS_QUEUE_NAME)

def lambda_handler(event, context):
    if not 'BUCKET_NAME' in os.environ or os.environ['BUCKET_NAME'] == "":
        print("PW3Query Error - 'BucketName' not found in environment variables.")
    
    BUCKET_NAME = os.environ['BUCKET_NAME']
    query_packs = []
    
    if 'Records' in event: #Trigger Events
        for record in event['Records']:
            file_key = record['s3']['object']['key']
            
            try:
                s3_obj = s3.get_object(Bucket=BUCKET_NAME, Key=file_key)
                query_pack = json.loads(s3_obj['Body'].read().decode('utf-8'))
            
                query_packs.append({"name":file_key, "queries":query_pack['queries'].items()})
            except:
                print("PW3Query Error - Unable to load query pack from " + file_key)
    else: #Scheduled dispatch
        for key in s3.list_objects(Bucket=BUCKET_NAME, Prefix=BUCKET_PREFIX, Delimiter="/")['Contents']:
            if key['Key'] == BUCKET_PREFIX:
                continue
        
            try:
                s3_obj = s3.get_object(Bucket=BUCKET_NAME, Key=key['Key'])
                query_pack = json.loads(s3_obj['Body'].read().decode('utf-8'))
            
                query_packs.append({"name":key['Key'], "queries":query_pack['queries'].items()})
            except:
                print("PW3Query Error - Unable to load query pack from " + key['Key'])
            
    for pack in query_packs:
        for query in pack['queries']:
            dispatch_query(query)
        print("PWQuery Info - dispatching ", len(pack['queries']), "queries found in", pack['name'])

def dispatch_query(query):
    try:
        sqs_queue.send_message(
            MessageBody=json.dumps(query),
            MessageGroupId='PW3QueryGroup'
        )
    except:
        print("PW3Query Error - Could not dispatch query to SQS: ", sys.exc_info())
