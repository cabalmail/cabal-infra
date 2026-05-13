# Recommended Steps for Setting Up Twilio for SMS Verification

Cabalmail delivers SMS verification codes (signup phone verification, password reset, MFA) through Twilio by way of a [Cognito custom SMS sender Lambda](https://docs.aws.amazon.com/cognito/latest/developerguide/user-pool-lambda-custom-sms-sender.html). This avoids AWS End User Messaging's toll-free verification queue, which in practice can take a month or longer. Twilio's approval flow is hours-to-days.

The Lambda, KMS key, and SSM secret parameters are all provisioned by Terraform. The manual steps below are the Twilio-side account setup, regulatory registration, and the GitHub Environment secrets that wire your Twilio credentials into the deploy pipeline.

## Account

1. [Sign up for a Twilio account](https://www.twilio.com/try-twilio). The free trial includes a small balance and a single trial phone number, both of which retire when you upgrade. Upgrade once you're ready to provision a number you intend to keep.
2. Optional but recommended for clean per-environment isolation: create [subaccounts](https://www.twilio.com/console/project/subaccounts) under the main account, one per environment you intend to enable (stage, prod). Each subaccount has its own Account SID and its own billing line, but they share the parent account's funding source and A2P brand registration.

## Phone number

Cabalmail can use either a US toll-free number or a US 10DLC (standard 10-digit) number. Both cost ~$1-2/month rental plus per-message charges in the cheapest tier.

1. Buy a number in [Console > Phone Numbers > Buy a number](https://console.twilio.com/us1/develop/phone-numbers/manage/search). The number must support SMS.
2. Make a note of the E.164-formatted number (e.g., `+15551234567`). You will need it for the `TWILIO_FROM_NUMBER` secret below.

## A2P 10DLC registration (required for US delivery on 10DLC)

US carriers (AT&T, T-Mobile, Verizon) require all Application-to-Person SMS on standard 10DLC numbers to be registered through The Campaign Registry. Without registration, carriers silently filter your messages and Twilio returns error code `30034: US A2P 10DLC - Message from an Unregistered Number`. The Twilio API will still accept the call, so the Lambda log will report success - the message just never reaches the handset.

Skip this section if you bought a toll-free number; see "Toll-free verification" below instead.

1. Register your **Brand** in [Console > Messaging > Regulatory Compliance > A2P 10DLC](https://console.twilio.com/us1/develop/sms/regulatory-compliance/a2p-10dlc). The form asks for business identity: legal name, EIN (or sole-proprietor flag), address, contact, website. Brand approval typically completes within a few hours.
2. Register a **Campaign** under the approved brand. For Cabalmail's verification-only use case, pick:
   - **Use case**: "Account Notification" or "Low Volume Mixed". The "2FA" category is also a fit if your registration form offers it.
   - **Sole Proprietor** is a separate fast track if you're registering as an individual rather than a business; it has tighter throughput limits but a simpler form.
   - **Sample messages**: include the exact verbatim copy the Lambda sends, e.g. `Your Cabalmail verification code is 123456` and `Your Cabalmail password reset code is 123456`.
3. Create a **Messaging Service** and attach the phone number you bought above. The Messaging Service is what binds the number to the campaign.

Campaign approval typically completes within hours to a few business days. Until it lands, expect 30034 errors and undelivered messages even though Twilio's API accepts the request.

## Toll-free verification (alternative to 10DLC)

If you bought a toll-free number instead of a 10DLC, fill out [Console > Messaging > Regulatory Compliance > Toll-Free Verifications](https://console.twilio.com/us1/develop/sms/regulatory-compliance/toll-free-verifications). Approval typically takes 1-3 business days.

## API key

Cabalmail authenticates to Twilio with an API Key (a scoped credential), not the account-level Auth Token.

1. In [Console > Account > API keys & tokens](https://console.twilio.com/us1/account/keys-credentials/api-keys), click "Create API key".
2. Type: **Standard**.
3. Make a note of the **SID** (starts with `SK...`) and the **Secret**. The secret is shown exactly once and cannot be retrieved later - if you lose it, you have to create a new key.

## GitHub Environment secrets

Add the following [GitHub Environment](https://docs.github.com/en/actions/managing-workflow-runs-and-deployments/managing-deployments/managing-environments-for-deployment) secrets to each environment where you want Twilio enabled (typically `stage` and `prod`; `development` is optional). Settings > Environments > [environment name] > Add secret.

| Secret | Value |
| --- | --- |
| `TWILIO_ACCOUNT_SID` | Twilio Account SID (starts with `AC...`). If you're using a subaccount, use the subaccount's SID, not the parent. |
| `TWILIO_API_KEY` | API Key SID from above (starts with `SK...`). |
| `TWILIO_API_SECRET` | API Key Secret from above. |
| `TWILIO_FROM_NUMBER` | Either the E.164 phone number (e.g., `+15551234567`) or a Messaging Service SID (starts with `MG...`). Once A2P 10DLC is approved, prefer the Messaging Service SID so messages route through the registered campaign. |

## Enable the feature flag

Add a [GitHub Environment variable](https://docs.github.com/en/actions/learn-github-actions/variables#defining-configuration-variables-for-multiple-workflows) (not a secret) named `TF_VAR_USE_TWILIO_SMS` with value `true` to each environment that should route SMS through Twilio. Default is `false`, which keeps Cognito on the legacy AWS End User Messaging / SNS path.

Then trigger the `infra.yml` workflow (any push to the named branch, or `workflow_dispatch`). Terraform will wire the custom SMS sender Lambda into the Cognito user pool. The next signup verification, password reset, or MFA code will be delivered by Twilio.

## Rollback

Set `TF_VAR_USE_TWILIO_SMS=false` (or remove the variable) and re-apply `infra.yml`. Cognito reverts to the SNS / AWS End User Messaging path immediately. The Twilio Lambda, KMS key, and SSM parameters all stay in place, so re-enabling later is a single-knob flip.
