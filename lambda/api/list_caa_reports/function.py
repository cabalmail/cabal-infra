'''Lists CAA iodef violation report records (admin only)'''
import os
import boto3  # pylint: disable=import-error
from helper import paged_report_response  # pylint: disable=import-error
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
    # Sorted on received time for reverse chronological order
    return paged_report_response(event, table, 'received', caa_report)


def caa_report(item):
    '''Maps a stored CAA report record onto its API shape'''
    raw_key = item.get('raw_key', '')
    return {
        'from_addr': item.get('from_addr', ''),
        'from_name': item.get('from_name', ''),
        'from_domain': item.get('from_domain', ''),
        'subject': item.get('subject', ''),
        'received': item.get('received', ''),
        'message_id': item.get('message_id', ''),
        'raw_url': sign_url(RAW_BUCKET, raw_key) if raw_key else ''
    }
