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
import dns.resolver # pylint: disable=import-error
from botocore.exceptions import ClientError # pylint: disable=import-error
from helper import IMAP_HOST # pylint: disable=import-error
from helper import get_imap_client # pylint: disable=import-error
from helper import get_object # pylint: disable=import-error
from helper import delete_object # pylint: disable=import-error

# --- Wedged-resolver armor --------------------------------------------------
# Since ~2026-07-05, in both stage and prod, this consumer's sandboxes hit
# getaddrinfo EBUSY for IMAP_HOST -- wedged for the container's entire life,
# from its very first call, across runtime versions -- while other names (S3,
# SQS) resolve fine in the same invocation, and while other lambdas (including
# cold starts and the other 512MB function) resolve IMAP_HOST fine. Only this
# consumer is exposed, and only this consumer is SQS-invoked; the event source
# (batch_size 1) pins redelivery to the same warm container, so an unguarded
# wedge traps the job until the DLQ. Crashing mid-invocation does not help --
# os._exit(1) was tried and the environment was reused anyway. Defenses:
#
# 1. Resolve IMAP_HOST once at import time (bottom of this block). On a
#    container wedged from birth with no working fallback this raises during
#    INIT, and a failed INIT makes Lambda discard the environment and
#    provision a fresh sandbox for the next delivery -- the retirement a
#    mid-invocation crash cannot achieve.
# 2. On EBUSY, resolve via a direct DNS query (dnspython) instead: its own
#    UDP socket to the resolv.conf nameserver, bypassing glibc's getaddrinfo
#    machinery entirely. Which rung answers is logged, so CloudWatch tells us
#    whether the wedge is glibc-internal or on the network path.
# 3. Shim socket.getaddrinfo for IMAP_HOST only, with the same ladder plus
#    the INIT-time answer as the last rung (covers a wedge that develops
#    after INIT). The shim answers with address tuples, so the TLS layer
#    still validates the certificate against the hostname.
#
# The NLB behind IMAP_HOST keeps its per-AZ addresses for its lifetime, so the
# cached last rung only goes stale if the NLB is replaced while this container
# is warm AND both resolution rungs are wedged at that moment; in that triple
# failure the connect fails and SQS retry/DLQ behaves as it did pre-shim.

_real_getaddrinfo = socket.getaddrinfo

# Modest timeouts so a black-holed direct query cannot eat the whole INIT.
_direct_resolver = dns.resolver.Resolver()
_direct_resolver.timeout = 3
_direct_resolver.lifetime = 5


def _direct_dns_query(port):
    '''Resolves IMAP_HOST's A records with a direct dnspython query and returns
    them shaped like getaddrinfo output.'''
    answers = _direct_resolver.resolve(IMAP_HOST, 'A')
    return [
        (socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_TCP, '',
         (rdata.address, port))
        for rdata in answers
    ]


def _rewrite_port(addrinfo, port):
    '''Returns addrinfo tuples with the sockaddr port replaced. The cached
    answer is keyed only by host, so serve whatever port the caller asked for
    (in practice always 993).'''
    return [
        (family, type_, proto, cname, (sockaddr[0], port) + sockaddr[2:])
        for family, type_, proto, cname, sockaddr in addrinfo
    ]


def _resolve_imap_host(port):
    '''The resolution ladder: glibc getaddrinfo, then a direct DNS query on
    EBUSY. Raises if both rungs fail (at INIT that fails the INIT, which is
    what makes Lambda replace a fully wedged sandbox).'''
    try:
        return _real_getaddrinfo(IMAP_HOST, port, 0, socket.SOCK_STREAM)
    except OSError as err:
        if err.errno != errno.EBUSY:
            raise
        print(f'[append-sent] getaddrinfo EBUSY for {IMAP_HOST}; '
              'trying a direct DNS query')
    addrinfo = _direct_dns_query(port)
    print(f'[append-sent] direct DNS query answered for {IMAP_HOST}: '
          f'{[sa[0] for *_, sa in addrinfo]}')
    return addrinfo


def _imap_getaddrinfo(host, port, *args, **kwargs):
    '''socket.getaddrinfo with the EBUSY ladder for IMAP_HOST. Installed
    module-wide below; socket.create_connection resolves getaddrinfo through
    the socket module's namespace at call time, so imapclient's connect goes
    through here.'''
    if host != IMAP_HOST:
        return _real_getaddrinfo(host, port, *args, **kwargs)
    try:
        fresh = _resolve_imap_host(port)
        _last_good['addrinfo'] = fresh
        return fresh
    except Exception as err:  # pylint: disable=broad-except
        print(f'[append-sent] both resolution rungs failed for {IMAP_HOST} '
              f'({err}); serving the address cached at INIT')
        return _rewrite_port(_last_good['addrinfo'], port)


# Deliberately at module scope: INIT is the one place a sandbox wedged from
# birth (on both rungs) can fail in a way that makes Lambda replace it.
_last_good = {'addrinfo': _resolve_imap_host(993)}
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
