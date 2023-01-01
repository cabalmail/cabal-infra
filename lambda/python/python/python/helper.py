import boto3
import botocore
from botocore.exceptions import ClientError
import io
import email
from imapclient import IMAPClient
from email.policy import default as default_policy

s3r = boto3.resource("s3")
s3c = boto3.client("s3",
                  region_name="us-east-1",
                  config=boto3.session.Config(signature_version='s3v4'))

ssm = boto3.client('ssm')
mpw = ssm.get_parameter(Name='/cabal/master_password',
                        WithDecryption=True)["Parameter"]["Value"]

def get_imap_client(host, user, folder):
    '''Returns an IMAP client for host/user with folder selected'''
    client = IMAPClient(host=host, use_uid=True, ssl=True)
    client.login(f"{user}*admin", mpw)
    client.select_folder(folder)
    return client

def get_folder_list(client):
    '''Retrieves IMAP folders'''
    response = client.list_folders()
    return decode_folder_list(response)

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

def get_message(host, user, folder, id, seen):
    '''Gets a message from cache on s3 or from imap server'''
    bucket = host.replace("imap", "cache")
    email_body_raw = b''
    key = f"{user}/{folder}/{id}/raw"
    if key_exists(bucket, key):
        email_body_raw = get_object(bucket, key)
    else:
        client = get_imap_client(host, user, folder)
        message = client.fetch([id],['RFC822'])
        if seen:
            client.add_flags([id], '\Seen', True)
        else:
            client.remove_flags([id], '\Seen', True)
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