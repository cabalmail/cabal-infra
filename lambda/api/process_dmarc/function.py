'''Ingests DMARC aggregate reports from the dmarc user's IMAP mailbox into DynamoDB'''
import email
import email.header
import gzip
import io
import json
import os
import re
import urllib.error
import urllib.request
import zipfile
import boto3  # pylint: disable=import-error
import imapclient  # pylint: disable=import-error
import defusedxml.ElementTree as ET  # pylint: disable=import-error
from defusedxml.common import DefusedXmlException  # pylint: disable=import-error

control_domain = os.environ['CONTROL_DOMAIN']
table_name = os.environ['DMARC_TABLE_NAME']
dmarc_user = os.environ.get('DMARC_USER', 'dmarc')
ping_param = os.environ.get('HEALTHCHECK_PING_PARAM', '')
XML_BUCKET = f'cache.{control_domain}'

ssm = boto3.client('ssm')
ddb = boto3.resource('dynamodb')
table = ddb.Table(table_name)
s3 = boto3.client('s3')

PROCESSED_FOLDER = 'INBOX.Processed'
SKIPPED_FOLDER = 'INBOX.Skipped'

# Phase 1 hardening caps (docs/0.10.x/application-surface-hardening-plan.md).
# Decompressed-attachment ceiling. A DMARC aggregate report is well under
# 10 MB uncompressed; 50 MB is generous for real reports and defeats zip and
# gzip bombs, which we read incrementally and abort once they cross the cap.
MAX_PAYLOAD_BYTES = int(os.environ.get('MAX_DMARC_PAYLOAD_BYTES', str(50 * 1024 * 1024)))
# Raw inbound message ceiling. Checked against RFC822.SIZE so we never download
# the body of an oversize message.
MAX_MESSAGE_BYTES = int(os.environ.get('MAX_DMARC_MESSAGE_BYTES', str(25 * 1024 * 1024)))
# Messages examined per scheduled run. The handler is idempotent and runs every
# few hours, so a backlog drains over successive runs rather than one unbounded
# fetch that could exhaust the Lambda.
MAX_MESSAGES_PER_RUN = int(os.environ.get('MAX_DMARC_MESSAGES_PER_RUN', '50'))
# Comma-separated allowlist of From: domains permitted to deliver reports.
# Subdomains of an allowlisted domain are also accepted. An empty value
# disables sender filtering (every sender is parsed).
DMARC_REPORT_SENDERS = frozenset(
    d.strip().lower()
    for d in os.environ.get('DMARC_REPORT_SENDERS', '').split(',')
    if d.strip()
)

_PING_URL = None


class PayloadTooLarge(Exception):
    '''Raised when a decompressed attachment exceeds MAX_PAYLOAD_BYTES.'''


def _ping_healthcheck():
    '''Best-effort heartbeat to Healthchecks. Silent on failure.'''
    global _PING_URL  # pylint: disable=global-statement
    if _PING_URL is None:
        if not ping_param:
            _PING_URL = ''
        else:
            try:
                resp = ssm.get_parameter(Name=ping_param, WithDecryption=True)
                value = resp['Parameter']['Value']
                _PING_URL = value if value.startswith('http') else ''
            except Exception as err:  # pylint: disable=broad-exception-caught
                print(f'healthcheck ping URL fetch failed: {err}')
                _PING_URL = ''
    if not _PING_URL:
        return
    try:
        with urllib.request.urlopen(_PING_URL, timeout=5) as resp:
            print(f'healthcheck ping -> {resp.status}')
    except (urllib.error.URLError, urllib.error.HTTPError, OSError) as err:
        print(f'healthcheck ping failed: {err}')


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


def ensure_folders(client):
    '''Creates the Processed and Skipped folders if they do not exist'''
    existing = [f[2] for f in client.list_folders()]
    for folder in (PROCESSED_FOLDER, SKIPPED_FOLDER):
        if folder not in existing:
            client.create_folder(folder)


def _read_capped(reader, cap):
    '''Reads at most cap+1 bytes from reader; raises PayloadTooLarge past cap.

    Decompressing incrementally and stopping one byte past the ceiling means a
    bomb never materialises in full - we abort as soon as it crosses the cap.
    '''
    data = reader.read(cap + 1)
    if len(data) > cap:
        raise PayloadTooLarge(f'decompressed size exceeds {cap} bytes')
    return data


def extract_xml_from_attachment(payload):
    '''Extracts DMARC XML from a zip or gzip attachment, capping decompressed size.

    Raises PayloadTooLarge if any container decompresses past MAX_PAYLOAD_BYTES.
    Returns None if no XML could be recovered from the attachment.
    '''
    # Try zip first
    try:
        with zipfile.ZipFile(io.BytesIO(payload)) as zf:
            for name in zf.namelist():
                if name.endswith('.xml'):
                    with zf.open(name) as entry:
                        return _read_capped(entry, MAX_PAYLOAD_BYTES)
    except zipfile.BadZipFile:
        pass

    # Try gzip
    try:
        with gzip.GzipFile(fileobj=io.BytesIO(payload)) as gz:
            return _read_capped(gz, MAX_PAYLOAD_BYTES)
    except (gzip.BadGzipFile, OSError, EOFError):
        pass

    # Try raw XML
    if payload.strip().startswith(b'<?xml') or payload.strip().startswith(b'<feedback'):
        if len(payload) > MAX_PAYLOAD_BYTES:
            raise PayloadTooLarge(f'raw XML exceeds {MAX_PAYLOAD_BYTES} bytes')
        return payload

    return None


def sender_domain(envelope):
    '''Lowercased domain of the envelope From: address, or '' when absent'''
    if envelope is None or not envelope.from_:
        return ''
    host = envelope.from_[0].host
    if isinstance(host, bytes):
        host = host.decode('ascii', errors='replace')
    return (host or '').strip().lower()


def sender_allowed(domain):
    '''True if filtering is disabled, or domain (or a parent) is allowlisted'''
    if not DMARC_REPORT_SENDERS:
        return True
    if domain in DMARC_REPORT_SENDERS:
        return True
    return any(domain.endswith('.' + allowed) for allowed in DMARC_REPORT_SENDERS)


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


def _safe_segment(value):
    '''Sanitises a string for safe use as part of an S3 key'''
    cleaned = re.sub(r'[^A-Za-z0-9._-]+', '_', value or '')
    return cleaned.strip('_') or 'unknown'


def xml_key_for(meta):
    '''Builds the S3 key under which the raw XML is stored'''
    return (
        f"dmarc/{_safe_segment(meta['date_end'])}/"
        f"{_safe_segment(meta['org_name'])}-{_safe_segment(meta['report_id'])}.xml"
    )


def upload_xml(xml_data, key):
    '''Uploads the raw DMARC report XML to S3'''
    try:
        s3.put_object(
            Bucket=XML_BUCKET,
            Key=key,
            Body=xml_data,
            ContentType='application/xml'
        )
        return True
    except Exception as err:  # pylint: disable=broad-exception-caught
        print(f'Failed to upload XML to s3://{XML_BUCKET}/{key}: {err}')
        return False


def write_records(records, xml_key):
    '''Writes parsed DMARC records to DynamoDB'''
    written = 0
    with table.batch_writer() as batch:
        for rec in records:
            item = {
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
            }
            if xml_key:
                item['xml_key'] = xml_key
            batch.put_item(Item=item)
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


def process_message(msg_data, counters):
    '''Processes a single email message, recording outcomes in counters.

    Decompression and XML-parse failures are categorised into counters rather
    than swallowed, so each can be alarmed on independently. Returns the count
    of records written from this message.
    '''
    msg = email.message_from_bytes(msg_data)
    total = 0
    found_attachment = False

    for part in msg.walk():
        content_type = part.get_content_type()
        filename = decode_filename(part.get_filename())

        if not is_dmarc_attachment(content_type, filename):
            continue

        payload = part.get_payload(decode=True)
        if not payload:
            continue

        found_attachment = True

        try:
            xml_data = extract_xml_from_attachment(payload)
        except PayloadTooLarge as err:
            counters['decompress_errors'] += 1
            print(f'[process_dmarc] oversize payload in {filename!r}: {err}')
            continue

        if xml_data is None:
            counters['decompress_errors'] += 1
            print(f'[process_dmarc] could not extract XML from {filename!r}')
            continue

        try:
            records = parse_dmarc_xml(xml_data)
        except (ET.ParseError, DefusedXmlException) as err:
            counters['xml_parse_errors'] += 1
            print(f'[process_dmarc] XML parse error in {filename!r}: {err}')
            continue

        if records:
            key = xml_key_for(records[0])
            stored = upload_xml(xml_data, key)
            wrote = write_records(records, key if stored else '')
            total += wrote
            counters['records'] += wrote
            print(f'[process_dmarc] wrote {wrote} records from {filename!r}')

    if not found_attachment:
        counters['no_attachment'] += 1

    return total


def _response(counters):
    '''Builds the Lambda response from the per-run counters'''
    return {
        'statusCode': 200,
        'body': json.dumps(counters)
    }


def handler(_event, _context):
    '''Fetches DMARC report emails and ingests them into DynamoDB'''
    counters = {
        'queued': 0,
        'processed': 0,
        'records': 0,
        'unknown_sender': 0,
        'oversize_message': 0,
        'no_attachment': 0,
        'decompress_errors': 0,
        'xml_parse_errors': 0,
        'errors': 0,
    }
    client = get_imap_client()
    try:
        ensure_folders(client)
        client.select_folder('INBOX')
        messages = client.search()
        counters['queued'] = len(messages)

        if not messages:
            print('[process_dmarc] no messages to process')
            _ping_healthcheck()
            print(f'[process_dmarc] run summary: {json.dumps(counters)}')
            return _response(counters)

        # Cap messages per run. The handler is scheduled and idempotent, so a
        # backlog drains over successive runs rather than one giant fetch.
        candidates = messages[:MAX_MESSAGES_PER_RUN]
        if len(messages) > len(candidates):
            print(f'[process_dmarc] {len(messages)} messages queued; '
                  f'processing first {len(candidates)} this run')

        # Cheap metadata pass: sender domain and size, so unwanted or oversize
        # messages are skipped before their full bodies are ever downloaded.
        meta = client.fetch(candidates, ['ENVELOPE', 'RFC822.SIZE'])

        to_fetch = []
        skipped_ids = []
        for msg_id in candidates:
            info = meta.get(msg_id, {})
            domain = sender_domain(info.get(b'ENVELOPE'))
            size = info.get(b'RFC822.SIZE', 0) or 0
            if not sender_allowed(domain):
                counters['unknown_sender'] += 1
                skipped_ids.append(msg_id)
                print(f'[process_dmarc] skip message {msg_id}: '
                      f'sender domain {domain!r} not in allowlist')
                continue
            if size > MAX_MESSAGE_BYTES:
                counters['oversize_message'] += 1
                skipped_ids.append(msg_id)
                print(f'[process_dmarc] skip message {msg_id}: '
                      f'size {size} exceeds {MAX_MESSAGE_BYTES} bytes')
                continue
            to_fetch.append(msg_id)

        processed_ids = []
        if to_fetch:
            fetched = client.fetch(to_fetch, ['RFC822'])
            for msg_id in to_fetch:
                data = fetched.get(msg_id)
                if not data or b'RFC822' not in data:
                    counters['errors'] += 1
                    print(f'[process_dmarc] message {msg_id}: empty RFC822 fetch')
                    continue
                try:
                    count = process_message(data[b'RFC822'], counters)
                    counters['processed'] += 1
                    processed_ids.append(msg_id)
                    print(f'[process_dmarc] message {msg_id}: {count} records')
                except Exception as err:  # pylint: disable=broad-exception-caught
                    counters['errors'] += 1
                    print(f'[process_dmarc] error processing message {msg_id}: {err}')

        # Move handled messages out of INBOX so each run sees only new mail and
        # skipped junk cannot accumulate to starve legitimate reports of the
        # per-run budget. Processed and skipped go to distinct folders so the
        # Skipped folder stays reviewable for allowlist tuning.
        if processed_ids:
            client.move(processed_ids, PROCESSED_FOLDER)
            print(f'[process_dmarc] moved {len(processed_ids)} processed '
                  f'messages to {PROCESSED_FOLDER}')
        if skipped_ids:
            client.move(skipped_ids, SKIPPED_FOLDER)
            print(f'[process_dmarc] moved {len(skipped_ids)} skipped '
                  f'messages to {SKIPPED_FOLDER}')

    finally:
        client.logout()

    _ping_healthcheck()

    print(f'[process_dmarc] run summary: {json.dumps(counters)}')
    return _response(counters)
