'''Confirms a pending (eagerly-created) email address

The browser extension creates addresses with pending=true at commit time so
DNS and the sendmail tier converge before any verification mail arrives, then
calls this endpoint on actual form submit (docs/1.x/browser-extension-plan.md,
Phase 3.1.b). Clearing the flag takes the address out of the TTL reaper's
scope and out of the imap tier's procmail-pending rule set.
'''
import json
import boto3  # pylint: disable=import-error
from botocore.exceptions import ClientError  # pylint: disable=import-error
from address_events import notify_containers  # pylint: disable=import-error
from helper import authorized_address_request  # pylint: disable=import-error

ddb = boto3.resource('dynamodb')
table = ddb.Table('cabal-addresses')


def handler(event, _context):
    '''Confirms a pending email address'''
    address, item, error = authorized_address_request(event)
    if error:
        return error
    if not item.get('pending'):
        # Already confirmed (the extension's submit handler may fire more than
        # once, and the procmail hook or the resubmit path may have won the
        # race). 409 is treated as success by the extension by contract.
        return {
            'statusCode': 409,
            'body': json.dumps({
                'Error': f"Address {address} is already confirmed"
            })
        }
    try:
        confirm_address(address)
        # Fan out so the imap tier drops the address's procmail-pending rule
        # promptly rather than on the next unrelated address change.
        notify_containers()
    except Exception as err:  # pylint: disable=broad-exception-caught
        print(f"Error confirming address {address}: {err}")
        return {
            'statusCode': 500,
            'body': json.dumps({
                'Error': str(err)
            })
        }
    return {
        'statusCode': 200,
        'body': json.dumps({
            'status': 'success',
            'address': address
        })
    }


def confirm_address(address):
    '''Clears the pending marker, tolerating a concurrent confirmation'''
    try:
        table.update_item(
            Key={'address': address},
            UpdateExpression='REMOVE #p, pending_since',
            # `pending` is a DynamoDB reserved word. The condition makes the
            # clear idempotent against the procmail clear-on-receive hook and
            # the reaper racing this call: a row already confirmed (or gone)
            # fails the condition and the update no-ops.
            ConditionExpression='attribute_exists(address) AND #p = :true',
            ExpressionAttributeNames={'#p': 'pending'},
            ExpressionAttributeValues={':true': True}
        )
    except ClientError as err:
        if err.response['Error']['Code'] != 'ConditionalCheckFailedException':
            raise
