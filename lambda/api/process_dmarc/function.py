'''Ingests DMARC aggregate reports from the dmarc user's IMAP mailbox into DynamoDB'''
import email
import email.header
import gzip
import io
import json
import os
import xml.etree.ElementTree as ET
import zipfile
import boto3  # pylint: disable=import-error
import imapclient  # pylint: disable=import-error

control_domain = os.environ['CONTROL_DOMAIN']
table_name = os.environ['DMARC_TABLE_NAME']
dmarc_user = os.environ.get('DMARC_USER', 'dmarc')

ssm = boto3.client('ssm')
ddb = boto3.resource('dynamodb')
table = ddb.Table(table_name)

PROCESSED_FOLDER = 'INBOX.Processed'


def get_master_password():
    '''Retrieves the master IMAP password from SSM'''
    return ssm.get_parameter(
        Name='/cabal/master_password',
        WithDecryption=True
    )['Parameter']['Value']


def get_imap_client():
    '''Connects to IMAP as the dmarc user via master-user authentication'''
    host = f'imap.{control_domain}'
    mpw = get_master_password()
    client = imapclient.IMAPClient(host, ssl=True)
    client.login(f'{dmarc_user}*admin', mpw)
    return client


def ensure_processed_folder(client):
    '''Creates the Processed folder if it does not exist'''
    folders = [f[2] for f in client.list_folders()]
    if PROCESSED_FOLDER not in folders:
        client.create_folder(PROCESSED_FOLDER)


def extract_xml_from_attachment(payload):
    '''Extracts DMARC XML from a zip or gzip attachment'''
    # Try zip first
    try:
        with zipfile.ZipFile(io.BytesIO(payload)) as zf:
            for name in zf.namelist():
                if name.endswith('.xml'):
                    return zf.read(name)
    except zipfile.BadZipFile:
        pass

    # Try gzip
    try:
        return gzip.decompress(payload)
    except (gzip.BadGzipFile, OSError):
        pass

    # Try raw XML
    if payload.strip().startswith(b'<?xml') or payload.strip().startswith(b'<feedback'):
        return payload

    return None


def _el_text(parent, tag, default=''):
    '''Safely extracts text from an XML child element'''
    el = parent.find(tag) if parent is not None else None
    return el.text if el is not None and el.text else default


def _parse_metadata(root):
    '''Extracts report metadata from the XML root'''
    metadata = root.find('report_metadata')
    if metadata is None:
        return None
    date_range = metadata.find('date_range')
    return {
        'org_name': _el_text(metadata, 'org_name', 'unknown'),
        'report_id': _el_text(metadata, 'report_id', 'unknown'),
        'date_begin': _el_text(date_range, 'begin', '0'),
        'date_end': _el_text(date_range, 'end', '0')
    }


def _parse_record(record, meta):
    '''Parses a single record element into a dict'''
    row = record.find('row')
    if row is None:
        return None
    policy = row.find('policy_evaluated')
    return {
        **meta,
        'source_ip': _el_text(row, 'source_ip'),
        'count': _el_text(row, 'count', '0'),
        'disposition': _el_text(policy, 'disposition'),
        'dkim_result': _el_text(policy, 'dkim'),
        'spf_result': _el_text(policy, 'spf'),
        'header_from': _el_text(record.find('identifiers'), 'header_from')
    }


def parse_dmarc_xml(xml_data):
    '''Parses RFC 7489 DMARC aggregate report XML into a list of records'''
    root = ET.fromstring(xml_data)
    meta = _parse_metadata(root)
    if meta is None:
        return []
    records = []
    for record in root.findall('record'):
        parsed = _parse_record(record, meta)
        if parsed:
            records.append(parsed)
    return records


def write_records(records):
    '''Writes parsed DMARC records to DynamoDB'''
    written = 0
    with table.batch_writer() as batch:
        for rec in records:
            batch.put_item(Item={
                'pk': f"{rec['header_from']}#{rec['date_end']}",
                'sk': f"{rec['source_ip']}#{rec['report_id']}",
                'org_name': rec['org_name'],
                'report_id': rec['report_id'],
                'date_begin': rec['date_begin'],
                'date_end': rec['date_end'],
                'source_ip': rec['source_ip'],
                'count': rec['count'],
                'disposition': rec['disposition'],
                'dkim_result': rec['dkim_result'],
                'spf_result': rec['spf_result'],
                'header_from': rec['header_from']
            })
            written += 1
    return written


def decode_filename(raw_filename):
    '''Decodes an RFC 2047 encoded filename'''
    if not raw_filename:
        return ''
    decoded_parts = email.header.decode_header(raw_filename)
    parts = []
    for part, charset in decoded_parts:
        if isinstance(part, bytes):
            parts.append(part.decode(charset or 'utf-8', errors='replace'))
        else:
            parts.append(part)
    return ''.join(parts)


def is_dmarc_attachment(content_type, filename):
    '''Checks whether a MIME part looks like a DMARC report attachment'''
    known_types = (
        'application/zip', 'application/gzip', 'application/x-gzip',
        'application/xml', 'text/xml', 'application/x-zip-compressed'
    )
    if content_type in known_types:
        return True
    if filename.endswith(('.zip', '.gz', '.xml')):
        return True
    # application/octet-stream is common; rely on the filename
    if content_type == 'application/octet-stream' and filename:
        return filename.endswith(('.zip', '.gz', '.xml'))
    return False


def process_message(msg_data):
    '''Processes a single email message, returns count of records written'''
    msg = email.message_from_bytes(msg_data)
    total = 0

    for part in msg.walk():
        content_type = part.get_content_type()
        filename = decode_filename(part.get_filename())

        if not is_dmarc_attachment(content_type, filename):
            continue

        payload = part.get_payload(decode=True)
        if not payload:
            continue

        xml_data = extract_xml_from_attachment(payload)
        if xml_data is None:
            print(f'Could not extract XML from attachment: {filename}')
            continue

        records = parse_dmarc_xml(xml_data)
        if records:
            total += write_records(records)
            print(f'Wrote {len(records)} records from {filename}')

    return total


def handler(_event, _context):
    '''Fetches DMARC report emails and ingests them into DynamoDB'''
    client = get_imap_client()
    try:
        ensure_processed_folder(client)
        client.select_folder('INBOX')
        messages = client.search()

        if not messages:
            print('No messages to process')
            return {
                'statusCode': 200,
                'body': json.dumps({'processed': 0, 'records': 0})
            }

        print(f'Found {len(messages)} messages to process')
        fetched = client.fetch(messages, ['RFC822'])
        total_records = 0
        processed_ids = []

        for msg_id, data in fetched.items():
            try:
                count = process_message(data[b'RFC822'])
                total_records += count
                processed_ids.append(msg_id)
                print(f'Message {msg_id}: {count} records')
            except Exception as err:  # pylint: disable=broad-exception-caught
                print(f'Error processing message {msg_id}: {err}')

        # Move processed messages to the Processed folder
        if processed_ids:
            client.move(processed_ids, PROCESSED_FOLDER)
            print(f'Moved {len(processed_ids)} messages to {PROCESSED_FOLDER}')

    finally:
        client.logout()

    return {
        'statusCode': 200,
        'body': json.dumps({
            'processed': len(processed_ids),
            'records': total_records
        })
    }
