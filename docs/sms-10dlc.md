# 10DLC SMS Registration

Cabalmail sends transactional SMS (signup phone verification, password
reset, sign-in MFA) from a US 10DLC number in AWS End User Messaging.
Before carriers deliver from a 10DLC number, the sending organization
and the message program must be registered and approved. Registration
is per AWS account, so each environment that sends SMS repeats this
process.

**Start this early.** SMS delivery gates signup itself — Cognito
verifies each new user's phone number by SMS at account creation, so
no one can register on a new system until this process completes. The
carrier reviews are the longest-lead items in a deployment, they can
take multiple rounds, and nothing else in the setup depends on them —
so begin as soon as the prerequisites below are satisfiable (in
practice: right after the front-door site resolves), and run the SNS
sandbox exit (see [setup.md](./setup.md)) in parallel rather than
after.

There are three layers:

| Layer | What it establishes | How it's managed |
|---|---|---|
| Brand registration | Who you are (legal entity, EIN) | Operator, via CLI or console; one-time |
| Campaign registration | What you send (use case, message texts, opt-in flow) | Operator, via CLI or console; iterate until approved |
| Phone number + keywords | The sending number and its HELP/STOP/START auto-responses | Terraform (`ten_dlc_campaign_registration_id`) + `put-sms-keywords.sh` post-apply step |

The registration review is performed by carriers against the *live*
product. The golden rule for every field: **describe only what is
actually deployed, and make the deployed thing compliant before you
describe it.** If a denial asks for something the product doesn't do
yet, change the product first, redeploy, re-screenshot, then resubmit.

## Prerequisites

1. **Consent surfaces deployed.** The signup form must collect SMS
   consent via a required, unchecked-by-default checkbox whose text
   names the brand, states message frequency and "message and data
   rates may apply", and gives HELP/STOP instructions. The front-door
   Terms and Privacy pages must carry the same disclosures. Both ship
   from this repo and render the operator identity from the
   `OPERATOR_NAME` / `TF_VAR_CONTROL_DOMAIN` GitHub variables, so a
   correctly configured deploy already conforms.
2. **Support mailbox.** `help@support.<control domain>` must exist and
   be monitored; reviewers sometimes probe it, and it appears in the
   HELP keyword response.
3. **Opt-in evidence screenshot.** A current screenshot of the live
   signup form (showing the consent checkbox and its full text) must be
   publicly reachable at `https://www.<control domain>/opt-in-screenshot.png`.
   It ships from `front-door/opt-in-screenshot.png`; recapture it
   whenever the signup copy changes.
4. **CLI permissions.** The commands below need `sms-voice:*` read
   plus `CreateRegistration`, `CreateRegistrationVersion`,
   `PutRegistrationFieldValue`, `DeleteRegistrationFieldValue`,
   `CreateRegistrationAssociation`, `ListRegistrationAssociations`,
   `SubmitRegistrationVersion`, and `DiscardRegistrationVersion`. The
   AWS console works too if you prefer forms over field paths.

## 1. Brand registration

```sh
aws pinpoint-sms-voice-v2 create-registration \
  --registration-type US_TEN_DLC_BRAND_REGISTRATION
```

Note the returned `RegistrationId`, then set each field with
`put-registration-field-value` and submit. The fields:

| Field path | Value |
|---|---|
| `companyInfo.companyName` | Exact legal name, e.g. `Example Holdings, LLC` |
| `companyInfo.legalType` | `PRIVATE_PROFIT` for an LLC |
| `companyInfo.address` / `.city` / `.state` / `.zipCode` / `.isoCountryCode` | Registered business address |
| `companyInfo.taxId` | EIN (digits only) |
| `companyInfo.taxIdIssuingCountry` | `US` |
| `contactInfo.dbaName` | Doing-business-as name; the legal name is fine |
| `contactInfo.supportEmail` | A monitored address on a domain you control |
| `contactInfo.supportPhoneNumber` | E.164, e.g. `+16035551234` |
| `contactInfo.vertical` | `COMMUNICATION` |
| `contactInfo.website` | `http://www.<control domain>` |

```sh
aws pinpoint-sms-voice-v2 put-registration-field-value \
  --registration-id <id> \
  --field-path companyInfo.companyName \
  --text-value "Example Holdings, LLC"
# ... repeat per field; select-type fields use --select-choices instead
aws pinpoint-sms-voice-v2 submit-registration-version --registration-id <id>
```

The brand is vetted against public records (state registration, IRS),
so the name, address, and EIN must match exactly what those records
say. Brand review is usually fast. Wait for `RegistrationStatus:
COMPLETE` before creating the campaign.

**The brand/DBA name is the string carriers match message texts
against.** Every keyword response and sample message in the campaign
must contain it (or something visibly close). Cabalmail's convention:
prefix every message with `Cabalmail (<legal name>):` so both the
product name and the registered brand appear.

## 2. Campaign registration

```sh
aws pinpoint-sms-voice-v2 create-registration \
  --registration-type US_TEN_DLC_CAMPAIGN_REGISTRATION
```

**Associate the campaign with the brand before submitting.** The
campaign's type definition declares the brand association as
`ASSOCIATE_BEFORE_SUBMIT`; the console creates this link implicitly,
the CLI does not, and an unassociated campaign is refused at
submission with `SUBMIT_REGISTRATION_VERSION_NOT_ALLOWED`:

```sh
aws pinpoint-sms-voice-v2 create-registration-association \
  --registration-id <campaign registration id> \
  --resource-id <brand registration id>
```

Field values that have passed carrier review, templated on
`<legal name>` (the registered brand) and `<control domain>`:

| Field path | Value |
|---|---|
| `campaignCapabilities.messageType` | `Transactional` |
| `campaignCapabilities.numberCapabilities` | `SMS` |
| `campaignUseCase.useCase` | `MIXED` |
| `campaignUseCase.subUseCases` | `TWO_FACTOR_AUTHENTICATION`, `ACCOUNT_NOTIFICATION` |
| `campaignUseCase.ageGated` / `.directLending` / `.embeddedLink` / `.embeddedPhone` | `No` |
| `campaignUseCase.subscriberOptIn` / `.subscriberOptOut` / `.subscriberHelp` | `Yes` |
| `campaignInfo.vertical` | `COMMUNICATION` |
| `campaignInfo.privacyPolicyLink` | `https://www.<control domain>/privacy.html` |
| `campaignInfo.termsAndConditionsLink` | `https://www.<control domain>/terms.html` |
| `campaignInfo.campaignName` | Required. A description paragraph, not a short name — see below |

`campaignInfo.campaignName` — despite the name, treat this as the
campaign *description*. Say who the operator is, what Cabalmail is,
and why it needs transactional SMS (account recovery for an email
service; relying on email alone risks permanent lock-out). If the
service is not yet open to the public, say so.

The message texts. Every one leads with the brand; the opt-in and HELP
texts carry the frequency and rates disclosures; ASCII only (GSM-7):

- `campaignInfo.optInMessage` —
  `Cabalmail (<legal name>): An account was requested with this phone number. Reply CONFIRM to verify. Msg frequency varies. Msg & data rates may apply. Reply HELP for help or STOP to cancel.`
- `campaignInfo.helpMessage` —
  `Cabalmail (<legal name>): For help, email help@support.<control domain> or visit https://www.<control domain>. Msg frequency varies. Msg & data rates may apply. Reply STOP to cancel.`
- `campaignInfo.stopMessage` —
  `Cabalmail (<legal name>): You are unsubscribed and will receive no further SMS. SMS-based account recovery is disabled. Reply START to resume.`
- `messageSamples.messageSample1` — the Cognito verification template
  with a literal code: `Your Cabalmail verification code is 123456.`
- `messageSamples.messageSample2` —
  `Your Cabalmail account password was changed. If this wasn't you, contact support immediately. Reply STOP to unsubscribe.`
- `messageSamples.messageSample3` —
  `Cabalmail (<legal name>): You are unsubscribed and will receive no further SMS. Reply START to resume.`

`campaignInfo.optInWorkflow` must describe every way consent is
collected, quote the deployed checkbox text verbatim, link the Terms
and Privacy pages, and cite the public evidence screenshot. If signup
is invitation-only, say so explicitly — it explains why reviewers
cannot walk the flow themselves. The shape that passed:

> User visits the Cabalmail signup page (operated by `<legal name>`)
> and enters their phone number. Consent is collected via a required,
> unchecked-by-default checkbox stating: '`<the deployed checkbox text,
> word for word>`' The form links the Terms of Service
> (https://www.`<control domain>`/terms.html) and Privacy Policy
> (https://www.`<control domain>`/privacy.html), both of which carry the
> full SMS program disclosures. The service is in a private,
> invitation-only phase, so the live signup flow is not publicly
> reachable; a screenshot of the live signup form showing the consent
> checkbox and all disclosures is publicly hosted at
> https://www.`<control domain>`/opt-in-screenshot.png

Then submit:

```sh
aws pinpoint-sms-voice-v2 submit-registration-version --registration-id <id>
```

If the submit is refused with `ConflictException` /
`SUBMIT_REGISTRATION_VERSION_NOT_ALLOWED` while the version is still
`DRAFT`, either the brand association is missing (see above; check
with `list-registration-associations`) or a required field is
missing. Find a missing field by diffing the draft against the field
definitions:

```sh
aws pinpoint-sms-voice-v2 describe-registration-field-definitions \
  --registration-type US_TEN_DLC_CAMPAIGN_REGISTRATION \
  --query 'RegistrationFieldDefinitions[?FieldRequirement==`REQUIRED`].FieldPath'
aws pinpoint-sms-voice-v2 describe-registration-field-values \
  --registration-id <id> --version-number <draft> \
  --query 'RegistrationFieldValues[].FieldPath'
```

Campaign review is typically fast (hours, not weeks). Poll with:

```sh
aws pinpoint-sms-voice-v2 describe-registrations
```

## 3. Iterating on a denial

A denial sets the registration to `REQUIRES_UPDATES`. Read the reasons
— they include field-level feedback that says exactly what the
reviewer wants:

```sh
aws pinpoint-sms-voice-v2 describe-registration-versions \
  --registration-id <id> --version-numbers <denied version>
aws pinpoint-sms-voice-v2 describe-registration-field-values \
  --registration-id <id> --version-number <denied version>
```

Fix the live product first if the denial calls for it (signup copy,
Terms/Privacy, screenshot), then open a new version and resubmit.

**Gotcha: a new version starts with NO field values.** It does not
inherit from the previous version. Replay every field, not just the
ones you changed, or the submission silently omits most of the form:

```sh
aws pinpoint-sms-voice-v2 create-registration-version --registration-id <id>
aws pinpoint-sms-voice-v2 describe-registration-field-values \
  --registration-id <id> --version-number <previous> --output json |
python3 -c '
import json, subprocess, sys
for fv in json.load(sys.stdin)["RegistrationFieldValues"]:
    cmd = ["aws", "pinpoint-sms-voice-v2", "put-registration-field-value",
           "--registration-id", sys.argv[1], "--field-path", fv["FieldPath"]]
    if "TextValue" in fv: cmd += ["--text-value", fv["TextValue"]]
    else: cmd += ["--select-choices"] + fv["SelectChoices"]
    subprocess.run(cmd, check=True)
' <id>
# ...then put the corrected fields over the top, and submit.
```

## 4. Provision the number and keywords

Once the campaign shows `RegistrationStatus: COMPLETE`:

1. Set `TF_VAR_TEN_DLC_CAMPAIGN_REGISTRATION_ID` to the campaign's
   `registration-...` id as a GitHub Environment variable on the
   target environment.
2. Ensure the CI deploy role has `sms-voice` permissions including
   `RequestPhoneNumber`, `ReleasePhoneNumber`, `UpdatePhoneNumber`,
   `DescribePhoneNumbers`, `PutKeyword`, `DescribeKeywords`, and
   `PutResourcePolicy` (the per-account Terraform policy is
   hand-managed; see [aws.md](./aws.md)).
3. Run `infra.yml` (any push touching `terraform/infra/**`, or a
   `workflow_dispatch`). Terraform requests the number against the
   campaign and waits for it to reach `ACTIVE`; the post-apply
   `set-sms-keywords` step then writes the HELP/STOP/START keyword
   responses so they match the registered texts, and
   `set-sms-resource-policy` shares the number with Amazon SNS.

**The resource policy is load-bearing.** Cognito sends SMS via SNS,
and SNS can only originate from an End User Messaging number whose
resource policy grants `sns.amazonaws.com` the
`sms-voice:SendTextMessage` action — *even within the owning account*.
The console's number-request wizard writes this policy when its "share
with Amazon SNS" box is checked, but numbers provisioned through the
`RequestPhoneNumber` API (as Terraform does) start with no policy.
Without it, every Cognito/SNS send fails with no error to the caller:
`sns:Publish` succeeds, nothing is billed or delivered, and only the
SNS delivery-status log (if enabled) records the reason —
`No origination identity available to send to destination number`.
Confusingly, the sandbox verification OTPs still arrive, because both
verification services send outside the SNS publish path — receiving an
OTP does not prove the path works.

Verify:

```sh
aws pinpoint-sms-voice-v2 describe-phone-numbers
aws pinpoint-sms-voice-v2 describe-keywords --origination-identity <phone number id>
aws pinpoint-sms-voice-v2 get-resource-policy --resource-arn <phone number ARN>
aws pinpoint-sms-voice-v2 send-text-message \
  --destination-phone-number <your mobile> \
  --message-body "Cabalmail smoke test" \
  --origination-identity <phone number id>
```

`get-resource-policy` must show the `sns.amazonaws.com` statement
described above. Note `send-text-message` exercises the End User
Messaging path only; it delivers even when the SNS path is broken. To
verify what Cognito actually uses, publish through SNS as well:

```sh
aws sns publish --phone-number <your mobile> \
  --message "Cabalmail SNS-path smoke test" \
  --message-attributes '{"AWS.SNS.SMS.SMSType":{"DataType":"String","StringValue":"Transactional"}}'
```

Text STOP and then START to the number to confirm the keyword
round-trip, and remember START is required to re-enable delivery to
your test phone afterward.

Cognito publishes SMS through SNS, which selects an origination
identity from the numbers available in the account — with the 10DLC
number `ACTIVE`, verification and MFA messages originate from it. Also
confirm the account has exited the SNS SMS sandbox and has an adequate
monthly spend limit (see [setup.md](./setup.md)).

## Costs

The brand registration, the campaign (recurring monthly), and the
number lease (recurring monthly) each carry fees — see
[AWS End User Messaging pricing](https://aws.amazon.com/end-user-messaging/pricing/)
before registering.
