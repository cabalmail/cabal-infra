import boto3
import botocore
from botocore.exceptions import ClientError
import io
s3r = boto3.resource("s3")
s3c = boto3.client("s3",
                  region_name="us-east-1",
                  config=boto3.session.Config(signature_version='s3v4'))
                  
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