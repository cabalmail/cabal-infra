'''SMTP connection dialing for the Lambda API (private-submission cutover).

The SMTP counterpart of imap_session's dual-path dial. When
SMTP_INTERNAL_HOST is set (the smtp-out task's Cloud Map name), the TCP
connection goes there directly - no NLB, no NAT hairpin - while TLS
verification keeps using the public submission hostname, because the
container serves the wildcard *.<control-domain> certificate. The split
lives in _get_socket: smtplib's SMTP_SSL wraps the socket with
server_hostname=self._host (the constructor's host argument, which
connect() never overwrites), so overriding only the TCP destination
leaves the certificate check real and unchanged.

Unlike the IMAP path, this dial FALLS BACK to the public listener when
the internal name does not resolve or refuses the connection. Cloud Map
registration happens at task START, so there is a window after the
first apply (and during any Cloud Map blip - the smtp tiers pin the
imap name in /etc/hosts for the same reason) where the name is empty;
/send is user-facing and SMTP-first, and the public listener is open
anyway, so failing the send to make a plumbing point would be pure
cost. The fallback prints a line so chronic use shows up in CloudWatch.
'''
import os
import smtplib
import ssl

INTERNAL_HOST = os.environ.get('SMTP_INTERNAL_HOST', '')


class _InternalRouteSMTPSSL(smtplib.SMTP_SSL):  # pylint: disable=too-few-public-methods
    '''SMTP_SSL whose TCP connection goes to the Cloud Map internal name
    while self._host (used for the TLS server_hostname) stays public.'''

    def _get_socket(self, host, port, timeout):
        # host arrives as the public name the constructor was given;
        # dial the internal name instead. The parent wraps the socket
        # with server_hostname=self._host, so verification still runs
        # against the public name the wildcard certificate carries.
        return super()._get_socket(INTERNAL_HOST, port, timeout)


def dial_smtp(host):
    '''Returns a connected smtplib.SMTP_SSL client.

    Internal path (SMTP_INTERNAL_HOST set): TCP to the Cloud Map name on
    465, TLS verified against `host`. Public path (unset, or internal
    dial fails): implicit TLS to host:465 via the NLB listener,
    byte-for-byte the original behavior.'''
    if INTERNAL_HOST:
        try:
            return _InternalRouteSMTPSSL(host)
        except ssl.SSLError:
            # SSLError subclasses OSError, so it must be re-raised before
            # the fallback clause: a certificate failure on the internal
            # path would fail on the public path too, and must surface,
            # not be quietly retried against a different socket.
            raise
        except OSError as err:
            # socket.gaierror (name not yet registered - Cloud Map
            # registers at task START) and connection refusals/timeouts.
            print(f'[smtp-session] internal dial to {INTERNAL_HOST} failed'
                  f' ({err}); falling back to public {host}')
    return smtplib.SMTP_SSL(host)
