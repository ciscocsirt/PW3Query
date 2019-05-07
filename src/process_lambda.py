import os
import boto3
import time
import json
import sys
import urllib.parse
from datetime import datetime, timedelta
from botocore.vendored import requests

s3 = boto3.client('s3')
sqs = boto3.client('sqs')
sqs_queue = sqs.get_queue_url(QueueName='PW3Query-Queue.fifo')

S3_BUCKET_PREFIX = "results/"
PW3_API_URL = "https://publicwww.com/websites/"
EXPECTED_QUERYPACK_KEYS = {'query', 'category', 'notes', 'snippet'}

def lambda_handler(event, context):
    if not 'BUCKET_NAME' in os.environ or os.environ['BUCKET_NAME'] == "":
        print("PW3Query Error - 'BUCKET_NAME' not found in environment variables.")
        return

    BUCKET_NAME = os.environ['BUCKET_NAME']

    message = get_message_from_queue()

    if validate_message(message):
        query_id = message[0]
        query_details = message[1]
        pw3_results = publicwww_request(query_details['query'],query_details['snippet'])
        if pw3_results and not pw3_results == "":
            formatted = format_results(query_id, query_details, pw3_results)
            output_to_s3(BUCKET_NAME,query_id,json.dumps(formatted))
        else:
            print("PW3Query Info - no publicwww results for",query_id)

# Validate Signature Keys
def validate_message(msg):
    if not msg or not len(msg) == 2:
        return False
        
    if not isinstance(msg[1], dict):
        return False
        
    if not set(msg[1].keys()) == EXPECTED_QUERYPACK_KEYS:
        return False

    return True
    
# Retrieve results from PublicWWW, if available.
def publicwww_request(querystr, snippet):
    try:
        #Create base URL
        url = PW3_API_URL + urllib.parse.quote(str(querystr).encode('utf-8'),safe='') + "/?export="
        
        #Append export type
        if snippet.lower() == "yes":
            url = url + "csvsnippets"
        else:
            url = url + "csv"
          
        #Append API key if available
        if 'PW3API_KEY' in os.environ and not os.environ['PW3API_KEY'] == "":
            url = url + "&key=" + os.environ['PW3API_KEY']
            
        print("PW3Query Info - PublicWWW API Request", url)
        return requests.get(url, timeout=500).text
    except:
        print("Error in PublicWWW Request: ", sys.exc_info())
        raise
        
#Format and add context
def format_results(query_id, query_details, results):
    formatted = []
    for line in results.splitlines():
        parts = str(line).split(';')
        if len(parts) >= 2:
            formatted.append({
                "domain":parts[0],
                "rank":parts[1],
                "snippet": parts[2] if len(parts) >= 3 else '',
                "queryId": query_id,
                "query": query_details['query'],
                "category": query_details['category'],
                "notes": query_details['notes']
            })
    return formatted 
    
def output_to_s3(BUCKET_NAME,query_id,results):
    utime1 = time.mktime((datetime.now() + timedelta(hours=-2)).replace(minute=0, second=0).timetuple())
    utime2 = str(int(utime1))[:-2]
    try:
        resp = s3.put_object(
            Body=results,
            Bucket=BUCKET_NAME,
            Key=S3_BUCKET_PREFIX + query_id + "_" + utime2
        )
    except:
        print("Error writing to S3: ", sys.exc_info())
        
    
def get_message_from_queue():
    response = sqs.receive_message(
        QueueUrl=sqs_queue['QueueUrl'],
        MaxNumberOfMessages=1, #Only get one message from the queue
        VisibilityTimeout=180,
        WaitTimeSeconds=0
    )

    if not ('Messages' in response and len(response['Messages']) > 0):
        return None
    
    #There should only be one message available
    msg = response['Messages'][0]
    msg_body = msg['Body']
    print(msg_body)

    #Remove the message from the queue immediately (avoid reprocessing)
    sqs.delete_message(
            QueueUrl=sqs_queue['QueueUrl'],
            ReceiptHandle=msg['ReceiptHandle']
    )
    return json.loads(msg['Body'])
