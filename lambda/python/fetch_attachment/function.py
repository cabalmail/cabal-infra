'''Preps an attachment for download from S3 given a mailbox, message ID, and attachment serial number'''
import json
import email
import boto3
import botocore
import logging
import io
from botocore.exceptions import ClientError
from datetime import datetime
from email.policy import default as default_policy

from imapclient import IMAPClient

logger = logging.getLogger()
logger.setLevel(logging.INFO)
s3 = boto3.client("s3",
                  region_name="us-east-1",
                  config=boto3.session.Config(signature_version='s3v4'))

def handler(event, _context):
    '''Preps an attachment for download from S3 given a mailbox, message ID, and attachment serial number'''
    body = json.loads(event['body'])
    bucket = body['host'].replace("admin", "cache")
    key = f"{body['user']}/{body['mailbox']}/{body['id']}/{body['index']}"
    client = IMAPClient(host=body['host'], use_uid=True, ssl=True)
    client.login(body['user'], body['password'])
    client.select_folder(body['mailbox'])
    email_body_raw = client.fetch([body['id']],[b"RFC822"])
    message = email.message_from_bytes(email_body_raw[body['id']][b"RFC822"], policy=default_policy)
    i = 0;
    if message.is_multipart():
        for part in message.walk():
            ct = part.get_content_type()
            cd = str(part.get('Content-Disposition'))
            i += 1
            if i == body['index']:
                upload_object(bucket, key, ct, part.get_payload)
    return {
        "statusCode": 303,
        "headers": {
            "Location": sign_url(bucket, key)
        }
    }

def sign_url(bucket, key, expiration=86400):
    params = {
        'Bucket': bucket,
        'Key': key
    }
    try:
        url = s3.generate_presigned_url('get_object',
                                        Params=params,
                                        ExpiresIn=expiration)
    except Exception as e:
        logging.error(e)
        return "Error"
    return url

def upload_object(bucket, key, content_type, obj):
    s3.upload_fileobj(obj, bucket, key)
    file_like_object = io.BytesIO(obj.__bytes__())
    try:
        s3.upload_fileobj(file_like_object, bucket, key, ExtraArgs={'ContentType': content_type})
    except ClientError as e:
        logging.error(e)
