import json
import boto3
import botocore
from botocore.exceptions import ClientError
from boto3.dynamodb.conditions import Key
import io
import email
from imapclient import IMAPClient
from email.policy import default as default_policy
import os
import dns.resolver

table = 'cabal-addresses'
region = os.environ['AWS_REGION']
ddb = boto3.resource('dynamodb')
ddb_table = ddb.Table(table)
s3r = boto3.resource("s3")
s3c = boto3.client("s3",
                  region_name=region,
                  config=boto3.session.Config(signature_version='s3v4'))

ssm = boto3.client('ssm')
mpw = ssm.get_parameter(Name='/cabal/master_password',
                        WithDecryption=True)["Parameter"]["Value"]

def get_mpw():
    """Returns the master password"""
    return mpw

def get_imap_client(host, user, folder, read_only=False):
    '''Returns an IMAP client for host/user with folder selected'''
    client = IMAPClient(host=host, use_uid=True, ssl=True)
    client.login(f"{user}*admin", mpw)
    client.select_folder(folder, read_only)
    return client

def user_authorized_for_sender(user, sender):
    """Checks whether the user is allowed to send from the specifed sender address"""
    try:
        response = ddb_table.get_item(Key={'address': sender})
    except ClientError as err:
        print(err.response['Error']['Message'])
        return False
    try:
        return response['Item']['user'] == user
    except KeyError:
        return False

def get_folder_list(client):
    '''
    Retrieves IMAP folders returning separate lists for all folders
    and subscribed folders
    '''
    all_folders = client.list_folders()
    sub_folders = client.list_sub_folders()
    return {
      'folders': decode_folder_list(all_folders),
      'sub_folders': decode_folder_list(sub_folders)
    }

def decode_folder_list(data):
    '''Converts folder list to simple list'''
    folders = []
    for m in data:
        folders.append(m[2].replace(".","/"))
    return sorted(folders, key=folder_sort)

def folder_sort(k):
    if k == 'INBOX':
        return k
    return k.lower()

def subscribe_folder(folder, host, user):
    client = get_imap_client(host, user, folder)
    return_value = client.subscribe_folder(folder)
    client.logout()
    return return_value

def unsubscribe_folder(folder, host, user):
    client = get_imap_client(host, user, folder)
    return_value = client.unsubscribe_folder(folder)
    client.logout()
    return return_value

def get_message(host, user, folder, id):
    '''Gets a message from cache on s3 or from imap server'''
    bucket = host.replace("imap", "cache")
    email_body_raw = b''
    key = f"{user}/{folder}/{id}/raw"
    if key_exists(bucket, key):
        email_body_raw = get_object(bucket, key)
    else:
        client = get_imap_client(host, user, folder, True)
        message = client.fetch([id],['RFC822'])
        email_body_raw = message[id][b'RFC822']
        client.logout()
        upload_object(bucket, key, "text/plain", email_body_raw)
    message = email.message_from_bytes(email_body_raw, policy=default_policy)
    return message

def upload_object(bucket, key, content_type, obj):
    '''Uploads an object to s3'''
    with io.BytesIO() as f:
        f.write(obj)
        f.seek(0)
        try:
            s3c.upload_fileobj(f, bucket, key, ExtraArgs={'ContentType': content_type})
        except ClientError as e:
            logging.error(e)
            return False
    return True

def get_object(bucket, key):
    '''Returns an object from s3'''
    obj = s3r.Object(bucket, key)
    return obj.get()['Body'].read()

def sign_url(bucket, key, expiration=86400):
    '''Signs a URL for an object hosted in s3'''
    params = {
        'Bucket': bucket,
        'Key': key
    }
    try:
        url = s3c.generate_presigned_url('get_object',
                                        Params=params,
                                        ExpiresIn=expiration)
    except Exception as e:
        logging.error(e)
        return "Error"
    return url

def key_exists(bucket, key):
    '''checks wither a key exists in a given bucket'''
    try:
        s3r.Object(bucket, key).load()
    except ClientError as e:
        if e.response['Error']['Code'] == "404":
            return False
        else:
            logging.error(e)
            return False
    return True