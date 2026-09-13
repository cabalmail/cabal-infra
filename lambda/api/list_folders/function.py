'''Retrieves IMAP folders for a user'''
import json
from helper import get_imap_client # pylint: disable=import-error
from helper import get_folder_list # pylint: disable=import-error
from helper import query_params # pylint: disable=import-error

from helper import maintenance_guard # pylint: disable=import-error


@maintenance_guard
def handler(event, _context):
    '''
    Retrieves IMAP folders for a user returning separate lists for all folders
    and subscribed folders
    '''
    try:
        query_string = query_params(event, 'host')
    except ValueError as err:
        return _invalid(err)
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    client = get_imap_client(query_string['host'], user, 'INBOX')
    response = get_folder_list(client)
    client.logout()
    return {
        "statusCode": 200,
        "body": json.dumps(response)
    }

def _invalid(err):
    '''Builds the 400 returned when a required parameter is missing.'''
    return {
        "statusCode": 400,
        "body": json.dumps({"status": f"Invalid input: {err}"})
    }
