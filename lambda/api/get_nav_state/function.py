'''Fetches the current user's navigation cursor (last folder/message/scroll).'''
import json
import os
from decimal import Decimal
import boto3  # pylint: disable=import-error

ddb = boto3.resource('dynamodb')
TABLE_NAME = os.environ.get('USER_PREFERENCES_TABLE_NAME', 'cabal-user-preferences')
table = ddb.Table(TABLE_NAME)


def _to_plain(value):
    '''Converts DynamoDB Decimal numbers back to int/float for JSON output.'''
    if isinstance(value, list):
        return [_to_plain(v) for v in value]
    if isinstance(value, dict):
        return {k: _to_plain(v) for k, v in value.items()}
    # boto3 returns numbers as Decimal. Decimal has no is_integer(), so match
    # it explicitly (the previous duck-type check missed it, leaving Decimals
    # that json.dumps could not serialize). The cursor stores whole numbers.
    if isinstance(value, Decimal):
        return int(value) if value == value.to_integral_value() else float(value)
    return value


def handler(event, _context):
    '''Returns the saved navigation cursor for the caller, or {} if none exists.'''
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    try:
        response = table.get_item(Key={'user': user})
        item = response.get('Item', {})
        nav_state = _to_plain(item.get('nav_state', {}))
    except Exception as err:  # pylint: disable=broad-exception-caught
        return {
            'statusCode': 500,
            'body': json.dumps({'Error': str(err)})
        }
    return {
        'statusCode': 200,
        'body': json.dumps(nav_state)
    }
