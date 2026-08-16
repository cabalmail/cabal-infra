'''Lists DMARC aggregate report records (admin only)'''
import os
import boto3  # pylint: disable=import-error
from helper import paged_report_response  # pylint: disable=import-error
from helper import sign_url  # pylint: disable=import-error
from admin_limits import admin_response_or_none  # pylint: disable=import-error

table_name = os.environ.get('DMARC_TABLE_NAME', 'cabal-dmarc-reports')
control_domain = os.environ['CONTROL_DOMAIN']
XML_BUCKET = f'cache.{control_domain}'

ddb = boto3.resource('dynamodb')
table = ddb.Table(table_name)


def handler(event, _context):
    '''Returns DMARC report records in reverse chronological order'''
    denial = admin_response_or_none(event)
    if denial:
        return denial
    # Sorted on date_end for reverse chronological order
    return paged_report_response(event, table, 'date_end', dmarc_report)


def dmarc_report(item):
    '''Maps a stored DMARC report record onto its API shape'''
    xml_key = item.get('xml_key', '')
    return {
        'org_name': item.get('org_name', ''),
        'report_id': item.get('report_id', ''),
        'date_begin': item.get('date_begin', ''),
        'date_end': item.get('date_end', ''),
        'source_ip': item.get('source_ip', ''),
        'count': item.get('count', '0'),
        'disposition': item.get('disposition', ''),
        'dkim_result': item.get('dkim_result', ''),
        'spf_result': item.get('spf_result', ''),
        'header_from': item.get('header_from', ''),
        'xml_url': sign_url(XML_BUCKET, xml_key) if xml_key else ''
    }
