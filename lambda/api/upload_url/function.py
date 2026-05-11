'''Issues presigned S3 PUT URLs for outbound attachments.

API Gateway caps a Lambda-proxy request at 10 MB, which forces a low
ceiling on inline-base64 attachments. This endpoint hands back one
presigned PUT URL per file so clients can upload bodies directly to the
existing cache bucket, then reference them by S3 key in the subsequent
/send call. The bucket's lifecycle rule (2 days, see
terraform/infra/modules/app/s3.tf) cleans up unused or already-sent
uploads.

Keys are namespaced `outbound/{cognito_username}/{uuid}/{filename}` so
the /send Lambda can verify a caller is only referencing keys it could
have written.
'''
import json
import os
import re
import uuid
from helper import sign_put_url # pylint: disable=import-error

KEY_PREFIX = 'outbound'
MAX_FILES_PER_REQUEST = 32
URL_EXPIRY_SECONDS = 600

# Allowed characters in a sanitized filename. S3 keys themselves are
# binary-safe, but we still strip path separators and control characters
# so a hostile filename can't escape the `outbound/<user>/<uuid>/` prefix
# the /send Lambda validates against.
_SAFE_FILENAME = re.compile(r'[^A-Za-z0-9._-]+')

def handler(event, _context):
    '''Returns a presigned PUT URL per requested attachment.'''
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    try:
        uploads = _build_uploads(event, user)
    except _RequestError as err:
        return _error(err.status, err.message)
    return {
        'statusCode': 200,
        'body': json.dumps({'uploads': uploads})
    }

def _build_uploads(event, user):
    try:
        body = json.loads(event['body'] or '{}')
    except ValueError as err:
        raise _RequestError(400, "invalid JSON body") from err

    files = body.get('files') or []
    if not isinstance(files, list) or not files:
        raise _RequestError(400, "files must be a non-empty list")
    if len(files) > MAX_FILES_PER_REQUEST:
        raise _RequestError(400, f"at most {MAX_FILES_PER_REQUEST} files per request")

    host = body.get('host')
    if not host or not isinstance(host, str):
        raise _RequestError(400, "host is required")
    bucket = host.replace('imap', 'cache')

    uploads = []
    for index, entry in enumerate(files):
        if not isinstance(entry, dict):
            raise _RequestError(400, f"file {index} is not an object")
        filename = entry.get('filename')
        if not filename or not isinstance(filename, str):
            raise _RequestError(400, f"file {index} is missing a filename")
        key = _build_key(user, filename)
        url = sign_put_url(bucket, key, expiration=URL_EXPIRY_SECONDS)
        if url == "Error":
            raise _RequestError(500, f"failed to sign upload URL for file {index}")
        uploads.append({
            'key': key,
            'url': url,
            'expires_in': URL_EXPIRY_SECONDS,
        })
    return uploads

class _RequestError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message

def _build_key(user, filename):
    safe_user = _SAFE_FILENAME.sub('_', user)
    base = os.path.basename(filename) or 'file'
    safe_filename = _SAFE_FILENAME.sub('_', base)
    return f"{KEY_PREFIX}/{safe_user}/{uuid.uuid4()}/{safe_filename}"

def _error(status, message):
    return {
        'statusCode': status,
        'body': json.dumps({'status': message})
    }
