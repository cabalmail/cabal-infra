# Password AutoFill in the native clients

The web app's login is saved by password managers against
`admin.<control-domain>`. For the iOS, macOS, and Android clients to be
offered that same login on their native sign-in forms, including its
one-time code on the MFA step, each platform has to be told that the app
and the domain belong together. That association is a two-sided
handshake: the app declares the domain, and the domain publishes a
document naming the app. This page covers both sides for both platforms.

Without the association, a password manager still lets you pick a login
by hand for the username and password fields, but verification-code
fill has no picker and simply never appears.

## Apple

**App side.** Both app targets carry the
`com.apple.developer.associated-domains` entitlement with a single entry,
`webcredentials:admin.$(CABALMAIL_CONTROL_DOMAIN)`. The domain is a build
setting, resolved at sign time:

| Context | Where the value comes from |
| --- | --- |
| CI upload jobs (`apple.yml`) | Passed on the `xcodebuild archive` command line from the GitHub environment variable `TF_VAR_CONTROL_DOMAIN`. If the variable is unset the job warns and keeps the placeholder. |
| Local signed build | `CABALMAIL_CONTROL_DOMAIN = <domain>` in `apple/Local.xcconfig` (see `Local.xcconfig.example`). |
| Nothing set | `Base.xcconfig` defaults it to `cabalmail.invalid`, a reserved name that can never resolve. The build signs; autofill just has nothing to match. |

The MFA field already carries the one-time-code content type, so no
view change is involved.

**Portal side.** The **Associated Domains** capability must be on the
`com.cabalmail.Cabalmail` and `com.cabalmail.CabalmailMac` App IDs, and
their App Store provisioning profiles regenerated afterwards, exactly as
for any capability change. See
[Creating provisioning profiles](apple.md#creating-provisioning-profiles).
Until the profiles carry the capability, signed archives fail at
codesign with an entitlement mismatch. Free personal teams cannot use
Associated Domains at all.

**Domain side.** Set the GitHub environment variable `TF_VAR_APPLE_TEAM_ID`
to the signing team's 10-character ID. Terraform then publishes
`https://admin.<control-domain>/.well-known/apple-app-site-association`
naming both apps under the `webcredentials` service. Leave it unset and
nothing is published.

Apple does not fetch that file from the device. Its CDN fetches it when
the app is installed and re-checks periodically, so a fresh publish can
take a while to take effect. Check what the CDN sees with:

```sh
curl -s https://app-site-association.cdn-apple.com/a/v1/admin.<control-domain>
```

and what the device resolved with `swcutil show` (macOS) or Settings →
Developer → Associated Domains Development (iOS). The distribution's
geo-restriction admits US viewers only; if the CDN check returns nothing
while the direct URL serves the file, that restriction is the first thing
to suspect.

## Android

**App side.** The sign-in fields declare autofill content types
(`Username`, `Password`, and `SmsOtpCode` on the MFA field, the only
one-time-code type the framework defines). Password managers key on
these to decide what to offer.

**Domain side.** Android matches an app to a site through
`https://admin.<control-domain>/.well-known/assetlinks.json`, which must
list the SHA-256 fingerprint of the certificate the installed APK is
signed with. With Play App Signing that is the **app signing key**
fingerprint from Play Console → Setup → App signing, not the upload key.
Debug builds are signed with the local debug keystore, whose fingerprint
`keytool -list -v -keystore ~/.android/debug.keystore` prints.

Set the GitHub environment variable
`TF_VAR_ANDROID_SIGNING_CERT_FINGERPRINTS` to an HCL list, escaping the
quotes exactly like `TF_VAR_MAIL_DOMAINS`:

```
[\"AA:BB:CC:...\",\"11:22:33:...\"]
```

Terraform publishes the document with the `get_login_creds` relation
only. Leave the variable unset and nothing is published; password
managers then fall back to asking once whether to link the app to the
web login, and remember the answer. Verify a published file with:

```sh
curl -s https://admin.<control-domain>/.well-known/assetlinks.json
```

## Testing

There is no automated coverage for the handshake itself; it depends on
the OS and the password manager. The click-test is the same on every
platform: save the web app's login in the password manager with its
one-time password attached, open the native app, and confirm the manager
offers that login on the username field and the code on the MFA step
without a manual search.
