'''Creates a new email address'''
import json
import os
from datetime import datetime, timezone
import boto3  # pylint: disable=import-error
from botocore.exceptions import ClientError  # pylint: disable=import-error
from address_events import notify_containers  # pylint: disable=import-error
from helper import new_address_response_or_none  # pylint: disable=import-error
from helper import parse_json_body  # pylint: disable=import-error
from helper import publish_address_dns_records  # pylint: disable=import-error
from helper import user_authorized_for_domain  # pylint: disable=import-error

domains = json.loads(os.environ['DOMAINS'])
control_domain = os.environ['CONTROL_DOMAIN']

ddb = boto3.resource('dynamodb')
table = ddb.Table('cabal-addresses')


def handler(event, _context):
    '''Creates a new email address'''
    body, error = parse_json_body(event)
    if error:
        return error
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    refusal = new_address_response_or_none(body, domains, control_domain)
    if refusal:
        return refusal
    if not user_authorized_for_domain(user, body['tld']):
        return {
            'statusCode': 403,
            'body': json.dumps({
                'Error': f"Not permitted to create addresses on \"{body['tld']}\""
            })
        }
    # Folded to lower case, as the mail tier folds every address: the table's
    # key is case-sensitive, so a key in the case the client typed would let
    # two concurrent creates of 'Foo' and 'foo' both pass the conditional put
    # in record_address and leave rows that collide in the sendmail maps.
    # Clients show the address the response returns.
    body['username'] = body['username'].lower()
    body['subdomain'] = body['subdomain'].lower()
    # Derive the address server-side rather than trusting body['address']: it is
    # the DynamoDB primary key and the value user_authorized_for_sender matches
    # on, so it must equal the real routing identity, not an arbitrary client
    # string. username/subdomain/tld are all validated above.
    address = f"{body['username']}@{body['subdomain']}.{body['tld']}"
    try:
        response = existing_address_response_or_none(user, address)
        if response is None:
            publish_address_dns_records(
                domains[body['tld']], body['subdomain'], body['tld'], control_domain)
            response = record_address(user, body, address)
    except Exception as err:  # pylint: disable=broad-exception-caught
        print(f"Error creating address {address}: {err}")
        return {
            'statusCode': 500,
            'body': json.dumps({
                'address': address,
                'error': str(err)
            })
        }
    return response


def created_response(address):
    '''The 201 a create answers with, whether it wrote the row or found the
    caller's own row already there'''
    return {
        'statusCode': 201,
        'body': json.dumps({
            'address': address
        })
    }


def conflict_response(sentence):
    '''A 409 carrying the sentence as both `Error` and `message`, because the
    clients read different keys'''
    return {
        'statusCode': 409,
        'body': json.dumps({
            'Error': sentence,
            'message': sentence
        })
    }


def taken_response(address):
    '''The 409 for an address that belongs to someone else'''
    return conflict_response(
        f"{address} is already taken. Choose another username or subdomain.")


def existing_address_response_or_none(user, address):
    '''Answers a create for an address that already has a row, or returns None
    when nothing stored matches it.

    The comparison ignores case. The mail tier folds addresses to lower case,
    so two rows that differ only in case would collide there. The handler
    folds the addresses it creates, but rows written before it did can hold
    upper case, and the table cannot be asked for a key regardless of case,
    so this reads every row's address and owners, a full scan like the one
    /list does.
    '''
    wanted = address.lower()
    for row in address_rows():
        if row['address'].lower() == wanted:
            return existing_address_response(user, address, row)
    return None


def existing_address_response(user, address, row):
    '''Answers a create that matched a stored row.

    The caller's own row comes back as a 201 with nothing written, so a repeated
    create leaves its owners, comment, pending and suspended state and
    favorites as they are. A row of the caller's that differs only in case is
    named in a 409, and anyone else's row is a 409.
    '''
    if user not in (row.get('user') or '').split('/'):
        return taken_response(address)
    if row['address'] != address:
        return conflict_response(f"You already have this address as {row['address']}.")
    return created_response(address)


def address_rows():
    '''Yields every row's address and owners, read consistently'''
    scan_kwargs = {
        # `user` is a DynamoDB reserved word.
        'ProjectionExpression': 'address, #u',
        'ExpressionAttributeNames': {'#u': 'user'},
        'ConsistentRead': True
    }
    while True:
        page = table.scan(**scan_kwargs)
        yield from page.get('Items', [])
        if 'LastEvaluatedKey' not in page:
            return
        scan_kwargs['ExclusiveStartKey'] = page['LastEvaluatedKey']


def record_address(user, body, address):
    '''Records the new address in DynamoDB and returns the response to send'''
    item = {
        'address': address,
        'tld': body['tld'],
        'user': user,
        'username': body['username'],
        'subdomain': body['subdomain'],
        'comment': body.get('comment', ''),
        'RequestTime': datetime.now(timezone.utc).isoformat()
    }
    # Eager-create support for the browser extension
    # (docs/1.x/browser-extension-plan.md, Phase 3.1.a): a pending address is
    # fully provisioned (DNS, sendmail maps) but unconfirmed. It is confirmed
    # by /confirm_address or by mail arriving (the imap tier's procmail hook),
    # and revoked by the reap_pending_addresses TTL reaper otherwise. Absent
    # or false means a normal, immediately-confirmed address, so existing
    # clients are unaffected.
    if body.get('pending') is True:
        item['pending'] = True
        item['pending_since'] = item['RequestTime']
    try:
        # A create of the same address can land between the handler's read
        # and this put. The condition makes the later put fail rather than
        # replace the earlier row; the handler folds case first, so that
        # includes a create that differs only in case.
        table.put_item(Item=item, ConditionExpression='attribute_not_exists(address)')
    except ClientError as err:
        if err.response['Error']['Code'] != 'ConditionalCheckFailedException':
            raise
        return existing_address_response_or_none(user, address) or taken_response(address)
    notify_containers()
    return created_response(address)
