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
import errno
import json
import socket
from botocore.exceptions import ClientError # pylint: disable=import-error
from helper import IMAP_HOST # pylint: disable=import-error
from helper import get_imap_client # pylint: disable=import-error
from helper import get_object # pylint: disable=import-error
from helper import delete_object # pylint: disable=import-error

# --- Wedged-resolver armor --------------------------------------------------
# The Lambda sandbox resolver can wedge such that getaddrinfo for IMAP_HOST
# fails with EBUSY for the container's entire life, while other names (S3,
# SQS) keep resolving in the same invocation. Only this consumer is exposed:
# interactive lambdas ride client retries onto other containers, but the SQS
# event source (batch_size 1) pins redelivery to the same warm container, so a
# wedged container traps the job until the DLQ. Crashing mid-invocation does
# not help -- os._exit(1) was tried and the environment was reused anyway.
# Two defenses:
#
# 1. Resolve IMAP_HOST once at import time (bottom of this block). On a
#    container wedged from birth this raises during INIT, and a failed INIT
#    makes Lambda discard the environment and provision a fresh sandbox for
#    the next delivery -- the retirement a mid-invocation crash cannot achieve.
# 2. Shim socket.getaddrinfo for IMAP_HOST only: try the live resolver first
#    (freshness), fall back to the INIT-time answer on EBUSY (a wedge that
#    develops after INIT). The shim answers with address tuples, so the TLS
#    layer still validates the certificate against the hostname.
#
# The NLB behind IMAP_HOST keeps its per-AZ addresses for its lifetime, so the
# cached answer only goes stale if the NLB is replaced while this container is
# warm AND the resolver is wedged at that moment; in that double failure the
# connect fails and SQS retry/DLQ behaves exactly as it did before the shim.

_real_getaddrinfo = socket.getaddrinfo


def _rewrite_port(addrinfo, port):
    '''Returns addrinfo tuples with the sockaddr port replaced. The cached
    answer is keyed only by host, so serve whatever port the caller asked for
    (in practice always 993).'''
    return [
        (family, type_, proto, cname, (sockaddr[0], port) + sockaddr[2:])
        for family, type_, proto, cname, sockaddr in addrinfo
    ]


def _imap_getaddrinfo(host, port, *args, **kwargs):
    '''socket.getaddrinfo with an EBUSY fallback for IMAP_HOST. Installed
    module-wide below; socket.create_connection resolves getaddrinfo through
    the socket module's namespace at call time, so imapclient's connect goes
    through here.'''
    if host != IMAP_HOST:
        return _real_getaddrinfo(host, port, *args, **kwargs)
    try:
        fresh = _real_getaddrinfo(host, port, *args, **kwargs)
        _last_good['addrinfo'] = fresh
        return fresh
    except OSError as err:
        if err.errno != errno.EBUSY:
            raise
        print(f'[append-sent] getaddrinfo EBUSY for {IMAP_HOST}; '
              'serving the address cached at INIT')
        return _rewrite_port(_last_good['addrinfo'], port)


# Deliberately at module scope: INIT is the one place a wedged-from-birth
# container can fail in a way that makes Lambda replace it.
_last_good = {'addrinfo': _real_getaddrinfo(IMAP_HOST, 993, 0, socket.SOCK_STREAM)}
socket.getaddrinfo = _imap_getaddrinfo
# -----------------------------------------------------------------------------


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
    # deliberately not guarded here. A wedged-resolver EBUSY is handled by the
    # getaddrinfo shim at the top of this module, not here.
    client = get_imap_client(None, user, 'INBOX')
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
