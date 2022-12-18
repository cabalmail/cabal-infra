import boto3
import botocore
from botocore.exceptions import ClientError
import io

s3 = boto3.client("s3",
                  region_name="us-east-1",
                  config=boto3.session.Config(signature_version='s3v4'))
                  
def upload_object(bucket, key, content_type, obj):
    '''Uploads an object to s3'''
    with io.BytesIO() as f:
        f.write(obj)
        f.seek(0)
        try:
            s3.upload_fileobj(f, bucket, key, ExtraArgs={'ContentType': content_type})
        except ClientError as e:
            logging.error(e)
            return False
    return True

def sign_url(bucket, key, expiration=86400):
    '''Signs a URL for an object hosted in s3'''
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
