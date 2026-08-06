'''Lists CAA iodef violation report records (admin only)'''
# pylint: disable=duplicate-code
import base64
import json
import os
import boto3  # pylint: disable=import-error
from helper import sign_url  # pylint: disable=import-error
from admin_limits import admin_response_or_none  # pylint: disable=import-error

table_name = os.environ.get('CAA_TABLE_NAME', 'cabal-caa-reports')
control_domain = os.environ['CONTROL_DOMAIN']
RAW_BUCKET = f'cache.{control_domain}'

ddb = boto3.resource('dynamodb')
table = ddb.Table(table_name)


def handler(event, _context):
    '''Returns CAA violation report records in reverse chronological order'''
    denial = admin_response_or_none(event)
    if denial:
        return denial
    try:
        params = event.get('queryStringParameters') or {}
        scan_kwargs = {
            'Limit': 50
        }

        next_token = params.get('next_token', '')
        if next_token:
            scan_kwargs['ExclusiveStartKey'] = json.loads(
                base64.b64decode(next_token).decode('utf-8')
            )

        response = table.scan(**scan_kwargs)
        items = response.get('Items', [])

        # Sort by received time descending for reverse chronological order
        items.sort(key=lambda x: x.get('received', '0'), reverse=True)

        reports = []
        for item in items:
            raw_key = item.get('raw_key', '')
            reports.append({
                'from_addr': item.get('from_addr', ''),
                'from_name': item.get('from_name', ''),
                'from_domain': item.get('from_domain', ''),
                'subject': item.get('subject', ''),
                'received': item.get('received', ''),
                'message_id': item.get('message_id', ''),
                'raw_url': sign_url(RAW_BUCKET, raw_key) if raw_key else ''
            })

        result = {'Reports': reports}

        last_key = response.get('LastEvaluatedKey')
        if last_key:
            result['NextToken'] = base64.b64encode(
                json.dumps(last_key).encode('utf-8')
            ).decode('utf-8')

    except Exception as err:  # pylint: disable=broad-exception-caught
        return {
            'statusCode': 500,
            'body': json.dumps({'Error': str(err)})
        }
    return {
        'statusCode': 200,
        'body': json.dumps(result)
    }
