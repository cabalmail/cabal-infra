'''Lists DMARC aggregate report records (admin only)'''
import base64
import json
import os
import boto3  # pylint: disable=import-error

table_name = os.environ.get('DMARC_TABLE_NAME', 'cabal-dmarc-reports')

ddb = boto3.resource('dynamodb')
table = ddb.Table(table_name)


def handler(event, _context):
    '''Returns DMARC report records in reverse chronological order'''
    groups = event['requestContext']['authorizer']['claims'].get('cognito:groups', '')
    if 'admin' not in groups:
        return {
            'statusCode': 403,
            'body': json.dumps({'Error': 'Admin access required'})
        }
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

        # Sort by date_end descending for reverse chronological order
        items.sort(key=lambda x: x.get('date_end', '0'), reverse=True)

        reports = []
        for item in items:
            reports.append({
                'org_name': item.get('org_name', ''),
                'report_id': item.get('report_id', ''),
                'date_begin': item.get('date_begin', ''),
                'date_end': item.get('date_end', ''),
                'source_ip': item.get('source_ip', ''),
                'count': item.get('count', '0'),
                'disposition': item.get('disposition', ''),
                'dkim_result': item.get('dkim_result', ''),
                'spf_result': item.get('spf_result', ''),
                'header_from': item.get('header_from', '')
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
