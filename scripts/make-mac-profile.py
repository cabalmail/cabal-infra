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

--replace deletes any existing profile with the same name before creating
the new one. The API refuses a duplicate name outright, and re-minting is
exactly what a capability change on the App ID demands (it invalidates the
old profile), so the collision is the normal case rather than an accident.
Deleting an invalidated profile is safe: CI installs profiles from the
GitHub secret, not by name, and the secret gets the new bytes anyway.
'''
import base64
import json
import os
import sys
import time
import urllib.parse
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


def api(token, path, body=None, method=None):
    '''One authenticated ASC API call; GET without a body, POST with one,
    or an explicit method (DELETE answers 204 with no body).'''
    request = urllib.request.Request(
        API + path,
        data=json.dumps(body).encode() if body else None,
        headers={'Authorization': f'Bearer {token}',
                 'Content-Type': 'application/json'},
        method=method or ('POST' if body else 'GET'))
    try:
        with urllib.request.urlopen(request) as response:
            return json.load(response) if response.status != 204 else None
    except urllib.error.HTTPError as err:
        sys.exit(f'ASC API {err.code} on {path}:\n{err.read().decode()}')


def main():
    '''Resolves the bundle id and certificates, creates the profile, and
    prints the base64 for the GitHub secret.'''
    args = [a for a in sys.argv[1:] if a != '--replace']
    replace = '--replace' in sys.argv[1:]
    if len(args) not in (2, 3):
        sys.exit('usage: make-mac-profile.py [--replace] <bundle-id> <profile-name> [profile-type]')
    bundle_id, name = args[0], args[1]
    profile_type = args[2] if len(args) == 3 else 'MAC_APP_STORE'

    token = asc_token()

    existing = api(token, f'/v1/profiles?filter[name]={urllib.parse.quote(name)}')['data']
    existing = [p for p in existing if p['attributes']['name'] == name]
    if existing and not replace:
        states = ', '.join(p['attributes'].get('profileState', '?') for p in existing)
        sys.exit(f'{len(existing)} profile(s) already named {name!r} ({states}); the API '
                 'refuses a duplicate name. Re-run with --replace to delete them first, '
                 'or pick another name.')
    for old_profile in existing:
        api(token, f"/v1/profiles/{old_profile['id']}", method='DELETE')
        print(f"deleted existing profile {old_profile['id']} "
              f"({old_profile['attributes'].get('profileState', '?')})")
    bundles = api(token, f'/v1/bundleIds?filter[identifier]={bundle_id}')['data']
    matches = [b for b in bundles if b['attributes']['identifier'] == bundle_id]
    if not matches:
        sys.exit(f'no registered App ID matches {bundle_id!r} - register it first')
    bundle = matches[0]

    # A profile inherits its entitlements from the App ID as configured at
    # mint time, and nothing downstream checks that until `-exportArchive`
    # validates the built product against it -- an archive signs happily
    # with a capability-less profile and the export then fails with
    # "doesn't include the App Groups capability". Show what the App ID
    # carries so the gap is visible before the profile exists.
    caps = api(token, f"/v1/bundleIds/{bundle['id']}/bundleIdCapabilities")['data']
    cap_types = sorted(c['attributes']['capabilityType'] for c in caps)
    print(f"App ID capabilities: {', '.join(cap_types) or '(none)'}")
    if 'APP_GROUPS' not in cap_types:
        print('  warning: APP_GROUPS is not enabled on this App ID. Every '
              'Cabalmail appex carries an application-groups entitlement, '
              'so a profile minted now will fail at export; enable App '
              'Groups on the App ID (and assign the group) first, then '
              're-run -- adding a capability invalidates existing profiles.')

    # A profile can only carry certificates of its own distribution family:
    # Apple Distribution for App Store profiles, Developer ID Application
    # for MAC_APP_DIRECT. The G2 flavor is the post-2021 Developer ID
    # sub-CA; profiles accept either, so both count. Fetched unfiltered and
    # matched client-side rather than via filter[certificateType], so an
    # enum-name mismatch surfaces as a clear "none eligible" message
    # instead of an opaque API 400.
    wanted = (
        {'DEVELOPER_ID_APPLICATION', 'DEVELOPER_ID_APPLICATION_G2'}
        if profile_type == 'MAC_APP_DIRECT'
        else {'DISTRIBUTION', 'MAC_APP_DISTRIBUTION'}
    )
    all_certs = api(token, '/v1/certificates?limit=200')['data']
    certs = [c for c in all_certs
             if c['attributes']['certificateType'] in wanted]
    if not certs:
        have = sorted({c['attributes']['certificateType'] for c in all_certs})
        sys.exit(
            f'no certificate on the team matches {profile_type} '
            f'(need one of {sorted(wanted)}; team has {have}). For a missing '
            'Developer ID Application certificate: only the Account Holder '
            'can create one, and a NEW cert means a new .p12 export and '
            're-minting every Developer ID profile against it.')
    for cert in certs:
        attrs = cert['attributes']
        print(f"  using certificate {attrs['certificateType']} "
              f"(expires {attrs.get('expirationDate', '?')[:10]})")
    print(f"bundleId {bundle['id']} ({bundle_id}); "
          f'{len(certs)} certificate(s) attached')

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
