'''Marks an email address as a favorite (or unfavorites it) for the calling user'''
import json
import boto3  # pylint: disable=import-error
from botocore.exceptions import ClientError  # pylint: disable=import-error

ddb = boto3.resource('dynamodb')
table = ddb.Table('cabal-addresses')


def handler(event, _context):
    '''Adds or removes the caller from the address's favorites set'''
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    body = json.loads(event['body'])
    address = body['address']
    favorite = bool(body['favorite'])
    try:
        item = table.get_item(Key={'address': address}).get('Item')
        if item is None:
            return {
                'statusCode': 404,
                'body': json.dumps({'Error': 'Address not found'})
            }
        assigned = item.get('user', '').split('/')
        if user not in assigned:
            return {
                'statusCode': 403,
                'body': json.dumps({
                    'Error': 'Address not associated with authenticated user'
                })
            }
        if favorite:
            table.update_item(
                Key={'address': address},
                UpdateExpression='ADD favorites :u',
                ExpressionAttributeValues={':u': {user}}
            )
        else:
            try:
                table.update_item(
                    Key={'address': address},
                    UpdateExpression='DELETE favorites :u',
                    ExpressionAttributeValues={':u': {user}}
                )
            except ClientError as err:
                # DynamoDB rejects DELETE on a missing set attribute; treat as no-op.
                if err.response['Error']['Code'] != 'ValidationException':
                    raise
    except Exception as err:  # pylint: disable=broad-exception-caught
        print(f"Error setting favorite on {address}: {err}")
        return {
            'statusCode': 500,
            'body': json.dumps({'Error': str(err)})
        }
    return {
        'statusCode': 200,
        'body': json.dumps({
            'address': address,
            'favorite': favorite
        })
    }
