#!/usr/bin/env python3
"""Mint a Chrome Web Store API refresh token for CI.

Uploading to the Web Store needs three credentials: an OAuth client ID and
client secret (which identify the *application*), and a refresh token (the
publisher account's standing grant). The first two come out of the Google
Cloud console; the third is a browser round-trip that has to be done once,
signed in as the account that owns the Web Store developer account.

Doing that by hand is unpleasant in three specific ways, all of which this
script removes: the authorization code arrives URL-encoded in a browser
address bar and must be decoded before use, it expires in about ten minutes
and is single-use, and the exchange request silently misbehaves if a shell
line continuation is mangled.

Run this on the machine whose browser is signed in as the publisher account.
It starts a one-shot listener on the redirect port, opens the consent screen,
captures the code, exchanges it, and prints the refresh token.

  ./scripts/mint-chrome-webstore-token.py --client-id <id> --client-secret <secret>

Then store all three, with the listing's item ID, as repository secrets:

  gh secret set CHROME_WEBSTORE_EXTENSION_ID
  gh secret set CHROME_WEBSTORE_CLIENT_ID
  gh secret set CHROME_WEBSTORE_CLIENT_SECRET
  gh secret set CHROME_WEBSTORE_REFRESH_TOKEN

Two prerequisites the console side must satisfy, because neither fails
loudly here: the OAuth client must be of type **Desktop Application** (the
"Chrome Extension" type is a secretless client for an unrelated feature and
cannot drive the upload API), and the consent screen's publishing status
must be **In production** — in Testing mode Google expires refresh tokens
after seven days, which silently kills unattended uploads weeks later.
"""

import argparse
import http.server
import json
import sys
import threading
import urllib.error
import urllib.parse
import urllib.request
import webbrowser

LOG_TAG = "[mint-chrome-webstore-token]"
SCOPE = "https://www.googleapis.com/auth/chromewebstore"
AUTH_ENDPOINT = "https://accounts.google.com/o/oauth2/auth"
TOKEN_ENDPOINT = "https://oauth2.googleapis.com/token"


class CodeCatcher(http.server.BaseHTTPRequestHandler):
    """One-shot handler that records the authorization code and says so."""

    code = None
    error = None

    def do_GET(self):  # noqa: N802 - name fixed by BaseHTTPRequestHandler
        """Record the code (or error) from the redirect and close the loop."""
        params = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        CodeCatcher.code = params.get("code", [None])[0]
        CodeCatcher.error = params.get("error", [None])[0]
        body = (b"<html><body><h1>Done.</h1><p>You can close this tab and "
                b"return to the terminal.</p></body></html>")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        """Silence the default request logging."""


def capture_code(port, timeout):
    """Serve one request on the redirect port and return the code it carries."""
    server = http.server.HTTPServer(("127.0.0.1", port), CodeCatcher)
    server.timeout = timeout
    thread = threading.Thread(target=server.handle_request, daemon=True)
    thread.start()
    thread.join(timeout)
    server.server_close()
    if CodeCatcher.error:
        sys.exit(f"{LOG_TAG} error: consent screen returned '{CodeCatcher.error}'")
    if not CodeCatcher.code:
        sys.exit(f"{LOG_TAG} error: no authorization code arrived within "
                 f"{timeout}s; re-run and complete the consent screen")
    return CodeCatcher.code


def exchange(client_id, client_secret, code, redirect_uri):
    """Trade the one-time authorization code for a refresh token."""
    data = urllib.parse.urlencode({
        "client_id": client_id,
        "client_secret": client_secret,
        "code": code,
        "grant_type": "authorization_code",
        "redirect_uri": redirect_uri,
    }).encode()
    request = urllib.request.Request(TOKEN_ENDPOINT, data=data, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return json.loads(response.read().decode())
    except urllib.error.HTTPError as err:
        sys.exit(f"{LOG_TAG} error: token exchange failed: {err.read().decode()}")


def main():
    """Run the consent round-trip and print the resulting refresh token."""
    parser = argparse.ArgumentParser(
        description="Mint a Chrome Web Store API refresh token.")
    parser.add_argument("--client-id", required=True, help="OAuth client ID")
    parser.add_argument("--client-secret", required=True, help="OAuth client secret")
    parser.add_argument("--port", type=int, default=8818,
                        help="loopback redirect port (default: 8818); it must "
                             "match a redirect URI on the OAuth client")
    parser.add_argument("--timeout", type=int, default=300,
                        help="seconds to wait for the redirect (default: 300)")
    parser.add_argument("--no-browser", action="store_true",
                        help="print the consent URL instead of opening it")
    args = parser.parse_args()

    redirect_uri = f"http://localhost:{args.port}"
    authorize_url = AUTH_ENDPOINT + "?" + urllib.parse.urlencode({
        "client_id": args.client_id,
        "response_type": "code",
        "scope": SCOPE,
        "redirect_uri": redirect_uri,
        # Both are load-bearing: without them Google issues an access token
        # and no refresh token, and the whole point here is the refresh token.
        "access_type": "offline",
        "prompt": "consent",
    })

    print(f"{LOG_TAG} listening on {redirect_uri}", file=sys.stderr)
    print(f"{LOG_TAG} approve as the account that owns the Web Store "
          f"developer account:\n\n{authorize_url}\n", file=sys.stderr)
    if not args.no_browser:
        webbrowser.open(authorize_url)

    code = capture_code(args.port, args.timeout)
    tokens = exchange(args.client_id, args.client_secret, code, redirect_uri)
    refresh_token = tokens.get("refresh_token")
    if not refresh_token:
        sys.exit(f"{LOG_TAG} error: Google returned no refresh token. The "
                 "client is probably not a Desktop Application client, or a "
                 "prior grant is being reused: revoke this app's access at "
                 "https://myaccount.google.com/permissions and re-run.")
    print(refresh_token)
    print(f"{LOG_TAG} store it: gh secret set CHROME_WEBSTORE_REFRESH_TOKEN",
          file=sys.stderr)


if __name__ == "__main__":
    main()
