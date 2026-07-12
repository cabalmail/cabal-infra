'''Minimal APNs provider-API client.

Two pieces the standard library lacks, built from pure-python wheels (see
requirements.txt for why no httpx/cryptography):

  * ES256 provider tokens (RFC 7519 JWT signed with the App Store Connect
    .p8 key) via python-ecdsa.
  * HTTP/2 request framing via h2 over an ALPN-negotiated TLS socket. APNs
    speaks HTTP/2 only.

One connection per warm Lambda container, reused across invocations and
reopened transparently when APNs (or an idle timeout) drops it. The client is
synchronous and single-stream: push_dispatch handles one wake signal per
invocation for a handful of device tokens, so pipelining would buy nothing.
'''
import base64
import hashlib
import json
import socket
import ssl
import time

import ecdsa  # pylint: disable=import-error
import ecdsa.util  # pylint: disable=import-error
import h2.connection  # pylint: disable=import-error
import h2.events  # pylint: disable=import-error
import h2.exceptions  # pylint: disable=import-error

# APNs provider tokens are valid for 20-60 minutes; refresh at 45 so a token
# is never presented near the edge of the window.
TOKEN_LIFETIME_SECONDS = 45 * 60

REQUEST_TIMEOUT_SECONDS = 10


class ApnsError(Exception):
    '''A non-2xx APNs response. `permanent` marks token-level rejections the
    caller should react to by pruning the device token, not by retrying.'''

    def __init__(self, status, reason):
        super().__init__(f'APNs {status}: {reason}')
        self.status = status
        self.reason = reason
        self.permanent = status == 410 or reason == 'BadDeviceToken'


class ApnsTransportError(Exception):
    '''The request never produced an APNs verdict: connect/TLS failure,
    timeout, dropped connection, or an HTTP/2 protocol violation — after the
    one transparent reconnect-and-retry. Always worth an SQS redelivery.'''


def _b64url(data):
    '''Base64url without padding, as JWTs require.'''
    return base64.urlsafe_b64encode(data).rstrip(b'=')


class ApnsClient:  # pylint: disable=too-few-public-methods
    '''Sends alert pushes to one APNs endpoint using provider-token auth.
    `send` is deliberately the whole surface.'''

    def __init__(self, endpoint, team_id, key_id, private_key_pem):
        self.host = endpoint.removeprefix('https://').strip('/')
        self.team_id = team_id
        self.key_id = key_id
        self.signing_key = ecdsa.SigningKey.from_pem(private_key_pem)
        self.token = (None, 0)  # (jwt, issued-at epoch seconds)
        self.sock = None
        self.conn = None

    def _provider_token(self):
        '''Returns a cached ES256 JWT, re-signing after TOKEN_LIFETIME.'''
        now = int(time.time())
        jwt, issued_at = self.token
        if jwt and now - issued_at < TOKEN_LIFETIME_SECONDS:
            return jwt
        header = _b64url(json.dumps({'alg': 'ES256', 'kid': self.key_id}).encode())
        claims = _b64url(json.dumps({'iss': self.team_id, 'iat': now}).encode())
        signing_input = header + b'.' + claims
        signature = self.signing_key.sign_deterministic(
            signing_input,
            hashfunc=hashlib.sha256,
            sigencode=ecdsa.util.sigencode_string,  # raw r||s, per JOSE
        )
        jwt = (signing_input + b'.' + _b64url(signature)).decode()
        self.token = (jwt, now)
        return jwt

    def _connect(self):
        '''Opens the TLS socket and performs the HTTP/2 connection preface.'''
        context = ssl.create_default_context()
        # create_default_context still admits TLS 1.0/1.1; APNs requires 1.2+
        # (and HTTP/2 forbids anything older), so pin the floor explicitly.
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.set_alpn_protocols(['h2'])
        raw = socket.create_connection((self.host, 443), timeout=REQUEST_TIMEOUT_SECONDS)
        self.sock = context.wrap_socket(raw, server_hostname=self.host)
        self.sock.settimeout(REQUEST_TIMEOUT_SECONDS)
        self.conn = h2.connection.H2Connection()
        self.conn.initiate_connection()
        self.sock.sendall(self.conn.data_to_send())

    def _close(self):
        if self.sock is not None:
            try:
                self.sock.close()
            except OSError:
                pass
        self.sock = None
        self.conn = None

    def _request(self, headers, body):
        '''Sends one request on the open connection; returns (status, body).'''
        stream_id = self.conn.get_next_available_stream_id()
        self.conn.send_headers(stream_id, headers)
        self.conn.send_data(stream_id, body, end_stream=True)
        self.sock.sendall(self.conn.data_to_send())

        status = None
        chunks = []
        deadline = time.monotonic() + REQUEST_TIMEOUT_SECONDS
        while True:
            if time.monotonic() > deadline:
                raise TimeoutError('timed out waiting for APNs response')
            data = self.sock.recv(65536)
            if not data:
                raise ConnectionError('APNs closed the connection mid-request')
            for event in self.conn.receive_data(data):
                if isinstance(event, h2.events.ResponseReceived) \
                        and event.stream_id == stream_id:
                    # h2 yields header names/values as bytes by default.
                    status = int(dict(event.headers)[b':status'].decode())
                elif isinstance(event, h2.events.DataReceived) \
                        and event.stream_id == stream_id:
                    chunks.append(event.data)
                    self.conn.acknowledge_received_data(
                        event.flow_controlled_length, stream_id)
                elif isinstance(event, h2.events.StreamEnded) \
                        and event.stream_id == stream_id:
                    self.sock.sendall(self.conn.data_to_send())
                    return status, b''.join(chunks)
                elif isinstance(event, h2.events.ConnectionTerminated):
                    raise ConnectionError('APNs terminated the connection')
            # Flush any acknowledgements/pings h2 queued while processing.
            self.sock.sendall(self.conn.data_to_send())

    def send(self, device_token, topic, payload, collapse_id):
        '''Sends one alert push. Returns None on success, raises ApnsError
        (permanent or not) on a non-2xx response, and raises
        ApnsTransportError when no verdict was obtained — after one
        transparent reconnect-and-retry.'''
        body = json.dumps(payload).encode()
        headers = [
            (':method', 'POST'),
            (':scheme', 'https'),
            (':authority', self.host),
            (':path', f'/3/device/{device_token}'),
            ('authorization', f'bearer {self._provider_token()}'),
            ('apns-topic', topic),
            ('apns-push-type', 'alert'),
            ('apns-priority', '10'),
            # apns-collapse-id caps at 64 bytes; longer would 400 the request.
            ('apns-collapse-id', collapse_id[:64]),
        ]
        for attempt in (1, 2):
            try:
                if self.conn is None:
                    self._connect()
                status, response = self._request(headers, body)
                break
            except (OSError, ConnectionError, ssl.SSLError,
                    h2.exceptions.ProtocolError) as err:
                # A dropped keep-alive connection (or an h2 state-machine
                # violation, which poisons the connection object) surfaces
                # here. Always close — a poisoned self.conn would otherwise
                # fail every request this warm container ever makes — then
                # reconnect once, then report a genuine outage.
                self._close()
                if attempt == 2:
                    raise ApnsTransportError(str(err)) from err
        if 200 <= status < 300:
            return
        reason = ''
        try:
            reason = json.loads(response.decode() or '{}').get('reason', '')
        except ValueError:
            pass
        raise ApnsError(status, reason)
