'''Lists all email addresses created by a user'''
import json
import boto3  # pylint: disable=import-error

ddb = boto3.resource('dynamodb')
table = ddb.Table('cabal-addresses')


def handler(event, _context):
    '''Lists all email addresses created by a user'''
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    try:
        response = table.scan(
            FilterExpression='#user = :user',
            ExpressionAttributeNames={
                '#user': 'user',
                '#c': 'comment'
            },
            ExpressionAttributeValues={
                ':user': user
            },
            ProjectionExpression='subdomain, #c, tld, address, username, #user'
        )
    except Exception as err:  # pylint: disable=broad-exception-caught
        return {
            'statusCode': 500,
            'body': json.dumps({
                'Error': str(err)
            })
        }
    response.pop('ResponseMetadata', None)
    return {
        'statusCode': 200,
        'body': json.dumps(response)
    }
