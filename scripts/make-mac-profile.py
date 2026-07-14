#!/usr/bin/env python3
'''Creates a macOS App Store provisioning profile via the App Store Connect API.

Why this exists: the Developer portal registers every new App ID as
platform-universal and offers no platform choice anywhere — not at App ID
registration, not in the profile-generation flow — and a profile created
through the portal UI against a universal App ID comes out iOS-family only
(Platform: iOS, xrOS, visionOS; no OSX), which macOS targets reject at
archive time. The API's profileType is explicit, so this is the supported
way to mint a macOS profile for a universal App ID.

Usage:
    python3 -m venv /tmp/ascvenv && /tmp/ascvenv/bin/pip install -q pyjwt cryptography
    ASC_KEY_ID=ABC123DEF4 \
    ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx \
    ASC_KEY_P8=~/keys/AuthKey_ABC123DEF4.p8 \
    /tmp/ascvenv/bin/python scripts/make-mac-profile.py \
        com.cabalmail.CabalmailMac.NotificationService \
        "Cabalmail macOS NSE App Store"

The three env vars are the same App Store Connect API key CI uses for
TestFlight uploads (APP_STORE_CONNECT_API_KEY_ID / _ISSUER_ID / _KEY_P8) —
keep the .p8 somewhere durable (password manager); Apple only lets you
download it once, and you will need it again whenever a mac profile has to
be re-minted (capability changes invalidate profiles).

Writes <profile-name>.provisionprofile next to the CWD, prints the base64
profileContent verbatim (paste it straight into the matching GitHub
secret), and reminds you of the platform check to run before uploading.

Optional third argument: the ASC profileType (default MAC_APP_STORE; use
MAC_APP_DIRECT for a Developer ID profile).
'''
import base64
import json
import os
import sys
import time
import urllib.request

try:
    import jwt  # pyjwt
except ImportError:
    sys.exit('pyjwt not installed - see the usage block at the top of this script')

API = 'https://api.appstoreconnect.apple.com'


def asc_token():
    '''Mints a short-lived ES256 App Store Connect API token from the env.'''
    missing = [v for v in ('ASC_KEY_ID', 'ASC_ISSUER_ID', 'ASC_KEY_P8')
               if not os.environ.get(v)]
    if missing:
        sys.exit(f"missing env vars: {', '.join(missing)} (see usage in the script header)")
    with open(os.path.expanduser(os.environ['ASC_KEY_P8']), encoding='utf-8') as key_file:
        key = key_file.read()
    now = int(time.time())
    return jwt.encode(
        {'iss': os.environ['ASC_ISSUER_ID'], 'iat': now, 'exp': now + 600,
         'aud': 'appstoreconnect-v1'},
        key, algorithm='ES256', headers={'kid': os.environ['ASC_KEY_ID']})


def api(token, path, body=None):
    '''One authenticated ASC API call; GET without a body, POST with one.'''
    request = urllib.request.Request(
        API + path,
        data=json.dumps(body).encode() if body else None,
        headers={'Authorization': f'Bearer {token}',
                 'Content-Type': 'application/json'},
        method='POST' if body else 'GET')
    try:
        with urllib.request.urlopen(request) as response:
            return json.load(response)
    except urllib.error.HTTPError as err:
        sys.exit(f'ASC API {err.code} on {path}:\n{err.read().decode()}')


def main():
    '''Resolves the bundle id and certificates, creates the profile, and
    prints the base64 for the GitHub secret.'''
    if len(sys.argv) not in (3, 4):
        sys.exit('usage: make-mac-profile.py <bundle-id> <profile-name> [profile-type]')
    bundle_id, name = sys.argv[1], sys.argv[2]
    profile_type = sys.argv[3] if len(sys.argv) == 4 else 'MAC_APP_STORE'

    token = asc_token()
    bundles = api(token, f'/v1/bundleIds?filter[identifier]={bundle_id}')['data']
    matches = [b for b in bundles if b['attributes']['identifier'] == bundle_id]
    if not matches:
        sys.exit(f'no registered App ID matches {bundle_id!r} - register it first')
    bundle = matches[0]

    certs = api(token, '/v1/certificates?filter[certificateType]=DISTRIBUTION&limit=50')['data']
    if not certs:
        sys.exit('no Apple Distribution certificates on the team')
    print(f"bundleId {bundle['id']} ({bundle_id}); "
          f'{len(certs)} distribution certificate(s) attached')

    profile = api(token, '/v1/profiles', {
        'data': {
            'type': 'profiles',
            'attributes': {'name': name, 'profileType': profile_type},
            'relationships': {
                'bundleId': {'data': {'type': 'bundleIds', 'id': bundle['id']}},
                'certificates': {'data': [
                    {'type': 'certificates', 'id': c['id']} for c in certs
                ]},
            },
        }})
    content = profile['data']['attributes']['profileContent']

    filename = name.replace(' ', '_') + '.provisionprofile'
    with open(filename, 'wb') as out:
        out.write(base64.b64decode(content))
    print(f'\nwrote {filename}')
    print('\nverify the platform BEFORE uploading the secret:')
    print(f'  security cms -D -i {filename} | plutil -p - | grep -A6 Platform')
    print('  (must list OSX)')
    print('\n=== base64 for the GitHub secret ===\n')
    print(content)


if __name__ == '__main__':
    main()
