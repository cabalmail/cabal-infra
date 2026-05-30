'''Lists all email addresses created by a user'''
import json
import boto3  # pylint: disable=import-error

ddb = boto3.resource('dynamodb')
table = ddb.Table('cabal-addresses')


def handler(event, _context):
    '''Lists all email addresses created by a user'''
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    try:
        items = []
        # Use contains() to narrow the scan, then exact-match the user
        # against slash-separated entries in Python to support multi-user
        # addresses while avoiding false positives like "chris" matching
        # "christopher".
        #
        # The 0.10.x hardening plan (Phase 5) proposed replacing this scan with
        # a query against a (user, address) GSI. That is deliberately NOT done:
        # multi-user addresses store the assignees slash-joined in the `user`
        # attribute (e.g. "alice/bob"), so a GSI partitioned on `user` would
        # file that row under "alice/bob" and a query for user="alice" would
        # silently miss it. A correct index needs a separate membership table
        # (one (user, address) row per assignee), which is a data-model change
        # out of scope here. The scan stays until then.
        scan_kwargs = {
            'FilterExpression': 'contains(#user, :user)',
            'ExpressionAttributeNames': {
                '#user': 'user',
                '#c': 'comment'
            },
            'ExpressionAttributeValues': {
                ':user': user
            },
            'ProjectionExpression': 'subdomain, #c, tld, address, username, #user, favorites'
        }
        while True:
            response = table.scan(**scan_kwargs)
            for item in response.get('Items', []):
                assigned = item.get('user', '').split('/')
                if user in assigned:
                    item['favorite'] = user in (item.pop('favorites', None) or set())
                    items.append(item)
            if 'LastEvaluatedKey' not in response:
                break
            scan_kwargs['ExclusiveStartKey'] = response['LastEvaluatedKey']
    except Exception as err:  # pylint: disable=broad-exception-caught
        return {
            'statusCode': 500,
            'body': json.dumps({
                'Error': str(err)
            })
        }
    return {
        'statusCode': 200,
        'body': json.dumps({'Items': items})
    }
