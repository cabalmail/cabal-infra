import json
import boto3
import botocore
from botocore.exceptions import ClientError
from boto3.dynamodb.conditions import Key
import io
import email
from imapclient import IMAPClient
from email.header import decode_header
from email.policy import default as default_policy
import os
import dns.resolver

table = 'cabal-addresses'
region = os.environ['AWS_REGION']
ddb = boto3.resource('dynamodb')
ddb_table = ddb.Table(table)
user_domain_access_table = ddb.Table('cabal-user-domain-access')
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

def admin_response_or_none(event):
    """Returns a 403 response when the caller lacks the admin group, else None"""
    groups = event['requestContext']['authorizer']['claims'].get('cognito:groups', '')
    if 'admin' not in groups:
        return {
            'statusCode': 403,
            'body': json.dumps({'Error': 'Admin access required'})
        }
    return None

def find_managed_apex(domains_map, domain):
    """Returns (apex, zone_id) for the longest managed apex that owns `domain`,
    or (None, None) when `domain` is not managed."""
    domain = (domain or '').lower().rstrip('.')
    best_apex = None
    best_zone = None
    for apex, zone_id in domains_map.items():
        apex_lower = apex.lower()
        if domain == apex_lower or domain.endswith('.' + apex_lower):
            if best_apex is None or len(apex_lower) > len(best_apex):
                best_apex = apex_lower
                best_zone = zone_id
    return (best_apex, best_zone)

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

def user_authorized_for_domain(user, domain):
    """Checks whether the user is permitted to create addresses on the given
    apex domain. The cabal-user-domain-access table is an allow list: a row
    keyed on (user, domain) means the user IS permitted. Missing row = deny.
    On lookup failure, default to deny so a transient DynamoDB error cannot
    silently grant access (and matches the default-deny policy of the table)."""
    try:
        response = user_domain_access_table.get_item(
            Key={'user': user, 'domain': domain}
        )
    except ClientError as err:
        print(err.response['Error']['Message'])
        return False
    return 'Item' in response

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

def sign_put_url(bucket, key, expiration=600):
    '''Signs a PUT URL for direct browser/native uploads to s3.

    The caller PUTs the file body straight to the returned URL, bypassing
    API Gateway's 10 MB request ceiling. The presigned URL only authorizes
    a single key, so the Lambda that issues it is responsible for scoping
    keys to the authenticated user. Content-Type is intentionally not
    bound here so clients can PUT without negotiating header values; the
    consumer of the uploaded object (currently `/send`) is the source of
    truth for the file's MIME type.
    '''
    params = {
        'Bucket': bucket,
        'Key': key
    }
    try:
        url = s3c.generate_presigned_url('put_object',
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


# Envelope decoders shared by /list_envelopes and /search_envelopes. Both
# endpoints return the same per-envelope JSON shape; the helpers live here so
# the wire format stays in sync and pylint's duplicate-code check stays quiet.

ENVELOPE_FETCH_KEYS = [
    'ENVELOPE', 'FLAGS', 'BODYSTRUCTURE', 'BODY[HEADER.FIELDS (X-PRIORITY)]'
]


def envelope_dict(msgid, data):
    '''Builds the per-envelope JSON payload from one IMAP fetch result entry.

    Callers are expected to have requested ENVELOPE_FETCH_KEYS in their fetch.
    The shape is consumed by the React webmail and the Apple `CabalmailKit`
    decoders, so changes here ripple to both clients.
    '''
    envelope = data[b'ENVELOPE']
    priority_header = data[b'BODY[HEADER.FIELDS (X-PRIORITY)]'].decode()
    return {
        "id": msgid,
        "date": str(envelope.date),
        "subject": decode_subject(envelope.subject),
        "from": decode_address(envelope.from_),
        "to": decode_address(envelope.to),
        "cc": decode_address(envelope.cc),
        "flags": decode_flags(data[b'FLAGS']),
        "struct": decode_body_structure(data[b'BODYSTRUCTURE']),
        "priority": [f"priority-{s}" for s in priority_header.split() if s.isdigit()]
    }


def decode_subject(data):
    '''Converts an email subject into a utf-8 string'''
    if data is None:
        return ''
    try:
        subject_parts = decode_header(data.decode())
    except UnicodeDecodeError:
        return "[[¿?]]"
    subject_strings = []
    for part in subject_parts:
        try:
            if isinstance(part[0], bytes):
                subject_strings.append(str(part[0], part[1] or 'utf-8'))
            if isinstance(part[0], str):
                subject_strings.append(part[0])
        except UnicodeDecodeError:
            subject_strings.append("[¿?]")
    return ''.join(subject_strings)


def decode_name(raw):
    '''Decodes an RFC 2047 encoded display name to a utf-8 string'''
    if raw is None:
        return ''
    try:
        if isinstance(raw, bytes):
            raw = raw.decode()
    except UnicodeDecodeError:
        return ''
    try:
        parts = decode_header(raw)
    except (UnicodeDecodeError, ValueError):
        return raw
    pieces = []
    for value, charset in parts:
        if isinstance(value, bytes):
            try:
                pieces.append(value.decode(charset or 'utf-8', errors='replace'))
            except (LookupError, UnicodeDecodeError):
                pieces.append(value.decode('utf-8', errors='replace'))
        else:
            pieces.append(value)
    return ''.join(pieces).strip()


def format_address(fragment):
    '''Renders one ENVELOPE address in RFC 5322 mailbox form, including display name when set'''
    mailbox = fragment.mailbox.decode()
    host = fragment.host.decode()
    addr = f"{mailbox}@{host}"
    name = decode_name(fragment.name)
    if name:
        # Quote and escape the display name for safe RFC 5322 rendering. Existing
        # clients parse `"Name" <addr@host>` via a `<...>` regex.
        escaped = name.replace('\\', '\\\\').replace('"', '\\"')
        return f'"{escaped}" <{addr}>'
    return addr


def decode_address(data):
    '''Converts a tuple of Address objects to a list of RFC 5322 mailbox strings'''
    return_value = []
    if isinstance(data, type(None)):
        return return_value
    for fragment in data:
        try:
            return_value.append(format_address(fragment))
        except: # pylint: disable=bare-except
            return_value.append("undisclosed-recipients")
    return return_value


def decode_flags(data):
    '''Converts array of bytes to array of strings'''
    return_value = []
    for flag in data:
        return_value.append(flag.decode())
    return return_value


def decode_body_structure(data):
    '''Converts bytes to strings in body structure'''
    return_value = []
    for obj in data:
        if isinstance(obj, list):
            return_value.append(decode_body_structure(obj))
        elif isinstance(obj, tuple):
            return_value.append(decode_body_structure(obj))
        elif isinstance(obj, bytes):
            return_value.append(obj.decode())
        else:
            return_value.append(obj)
    return return_value