'''SQS consumer that appends a delivered message's copy to the user's Sent
folder.

Decoupled from /send so outbound delivery never blocks on IMAP: /send delivers
over SMTP, stages the Bcc-free copy to S3, and enqueues a job here. During a
planned IMAP roll get_imap_client raises (MaintenanceError, or a plain
connection failure on a genuine outage), the record is left on the queue, and
SQS redelivers it after the visibility timeout until the new IMAP container is
serving. After the queue's maxReceiveCount the record lands in the DLQ.

The event source mapping uses batch_size 1 so a single failing job retries on
its own rather than dragging a whole batch with it.'''
import json
from botocore.exceptions import ClientError # pylint: disable=import-error
from helper import get_imap_client # pylint: disable=import-error
from helper import get_object # pylint: disable=import-error
from helper import delete_object # pylint: disable=import-error


def handler(event, _context):
    '''Appends each queued message to its user's Sent folder. Raises on failure
    so SQS redelivers (and ultimately routes to the DLQ); a clean return ack's
    the record.'''
    for record in event.get('Records', []):
        _process(json.loads(record['body']))
    return {"statusCode": 200}


def _process(job):
    '''Appends one staged message to Sent, idempotently, then deletes the stage.'''
    bucket = job['bucket']
    key = job['key']
    user = job['user']
    host = job['host']
    message_id = job.get('message_id') or ''

    try:
        raw = get_object(bucket, key)
    except ClientError as err:
        # A duplicate delivery for a job we already completed (the stage is
        # deleted on success). Nothing to do - ack so it does not loop to the DLQ.
        if err.response['Error']['Code'] in ('NoSuchKey', '404'):
            print(f'[append-sent] staged object {key} gone; assuming already appended')
            return
        raise

    # Connect to INBOX (always present); create/select Sent ourselves so a fresh
    # mailbox without a Sent folder still works. get_imap_client raises during a
    # planned IMAP roll, which is exactly when we WANT the job to retry, so it is
    # deliberately not guarded here.
    client = get_imap_client(host, user, 'INBOX')
    try:
        try:
            client.create_folder('Sent')
        except Exception:  # pylint: disable=broad-except
            pass  # already exists
        client.select_folder('Sent')
        if message_id and _already_in_sent(client, message_id):
            print(f'[append-sent] {message_id} already in Sent; skipping append')
        else:
            client.append('Sent', raw, flags=[rb"\Seen"])
    finally:
        client.logout()

    delete_object(bucket, key)


def _already_in_sent(client, message_id):
    '''Idempotency guard against a duplicate SQS delivery: True if a message with
    this Message-Id is already in the (selected) Sent folder. On a SEARCH error
    returns False - a duplicate Sent copy is a better failure than a lost one.'''
    try:
        return bool(client.search(['HEADER', 'MESSAGE-ID', message_id]))
    except Exception:  # pylint: disable=broad-except
        return False
