# AWS End User Messaging Toll-Free Verification (TFV) Setup

Cabalmail uses an AWS End User Messaging toll-free number for transactional SMS (signup phone verification, password reset, sign-in MFA). The phone number is provisioned by Terraform when `TF_VAR_USE_EUM_SMS=true`, but it sits in `Pending` status until you submit a **toll-free verification** (TFV) registration. AWS does not surface this requirement anywhere in the console flow - the number simply waits.

This guide walks you through the one-time operator steps to submit the TFV registration via the `register-tfv` GitHub Actions workflow. After submission, carrier review takes 5-15 business days; until it completes, SMS does not deliver.

## Prerequisites

Before you trigger the workflow:

1. **EUM toll-free number provisioned.** Confirm `TF_VAR_USE_EUM_SMS=true` is set as a GitHub Environment variable on the target environment (`stage` and/or `prod`) and that `infra.yml` has applied successfully. The number should appear in the [AWS End User Messaging console](https://console.aws.amazon.com/sms-voice/home) under **Configurations -> Phone numbers** with status `Pending`.
2. **Front door site deployed.** The privacy policy and terms of service must be reachable at `https://www.<control_domain>/privacy.html` and `https://www.<control_domain>/terms.html` respectively. The bucket and CloudFront distribution are provisioned by the `front_door` Terraform module and the content ships via the `front_door` area of `.github/workflows/app.yml` (see [front-door.md](front-door.md)).
3. **Opt-in screenshot.** AWS requires a screenshot of the signup screen showing the SMS consent language. Capture a screenshot of the Cabalmail admin signup form (the panel with the username + phone number fields and the paragraph reading "By creating an account you agree to the Terms and Privacy Policy, and to receive transactional SMS..."). Save as a PNG, ideally under 1 MB.

   You have two delivery options:
   - **Commit it to the repo.** Save the file as `front-door/opt-in-screenshot.png`. The workflow picks it up automatically.
   - **Host it elsewhere.** Pass an HTTPS URL via the `opt_in_image_url` workflow input. The workflow fetches it at run time. This avoids committing a binary that may need to be regenerated whenever the signup screen changes.

4. **IAM permissions on the `terraform` user.** The workflow re-uses the existing `terraform` IAM user's credentials (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`) from the `infra.yml` workflow. That user does not have `sms-voice:*` permissions by default; attach the inline policy below before triggering the workflow for the first time on each AWS account. The policy is intentionally action-scoped rather than wildcarded so future API additions are reviewable.

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Sid": "CabalmailTFVSubmission",
         "Effect": "Allow",
         "Action": [
           "sms-voice:DescribePhoneNumbers",
           "sms-voice:DescribeRegistrations",
           "sms-voice:DescribeRegistrationFieldDefinitions",
           "sms-voice:DescribeRegistrationVersions",
           "sms-voice:DescribeRegistrationFieldValues",
           "sms-voice:DescribeRegistrationAttachments",
           "sms-voice:ListRegistrationAssociations",
           "sms-voice:CreateRegistration",
           "sms-voice:CreateRegistrationVersion",
           "sms-voice:CreateRegistrationAttachment",
           "sms-voice:PutRegistrationFieldValue",
           "sms-voice:CreateRegistrationAssociation",
           "sms-voice:SubmitRegistrationVersion"
         ],
         "Resource": "*"
       }
     ]
   }
   ```

   AWS Console -> IAM -> Users -> `terraform` -> **Add permissions -> Create inline policy** -> JSON tab -> paste -> name it `CabalmailTFVSubmission`. Same procedure on each AWS account you intend to submit a TFV registration from (stage, prod).

## GitHub Environment configuration

For each environment you want to enable TFV in (typically `stage` first, then `prod`), set the `TFV_*` variables and secrets under Settings -> Environments -> [environment name]. The full list of names, examples, and descriptions is in [docs/github.md](github.md#tfv-registration). The `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and `AWS_REGION` repository secrets are reused from `infra.yml` and do not need to be duplicated.

## Triggering the workflow

1. GitHub -> Actions -> "Submit AWS End User Messaging TFV" -> **Run workflow**.
2. Pick the target environment (`stage` or `prod`).
3. Either leave `opt_in_image_url` empty (uses the file at `front-door/opt-in-screenshot.png` if committed) or paste a public HTTPS URL to the screenshot.
4. Click **Run workflow**.

The job will:

1. Look up the toll-free phone number on the account.
2. Find an existing TFV registration for that number, or create a new one.
3. Upload the opt-in screenshot as a registration attachment.
4. Set every required field from the env vars above.
5. Associate the phone number with the registration.
6. Submit the latest version for carrier review.

Final output includes the registration ID and a `describe-registrations` command you can run to poll status.

## Tracking status

```
aws pinpoint-sms-voice-v2 describe-registrations \
  --registration-ids <id from workflow output> \
  --region <your AWS region>
```

Status progression: `DRAFT` (before submit) -> `REVIEWING` (carrier review) -> `COMPLETE` (approved, number can deliver) **or** `REQUIRES_UPDATES` (carrier rejected; reason in `RegistrationVersionStatusHistory`).

## Handling REQUIRES_UPDATES

If the registration comes back `REQUIRES_UPDATES`:

1. Read the rejection reason in the AWS console (Configurations -> Registrations -> your registration -> View history) or via `describe-registration-versions`.
2. Fix the corresponding GitHub Environment variable (typically `TFV_USE_CASE_DETAILS`, `TFV_OPT_IN_DESCRIPTION`, or the opt-in screenshot).
3. Re-run the workflow. The script is idempotent: it re-applies all field values to the existing registration and re-submits.

## After approval

Once status is `COMPLETE`:

1. The number can deliver SMS via Amazon SNS (Cognito's `sms_configuration` path).
2. Test end-to-end with a signup flow at `https://admin.<control_domain>` using a phone number you control.
3. If you want to fully retire Twilio at this point, set `TF_VAR_USE_TWILIO_SMS=false` in the GitHub Environment and re-run `infra.yml`. Cognito will start routing SMS through SNS / EUM instead of Twilio. See [twilio.md](twilio.md) for the rollback semantics.

## Common rejection reasons

- **Privacy policy URL inaccessible or missing required language.** The page at `TFV_COMPANY_WEBSITE/privacy.html` must explicitly cover SMS use, message frequency, STOP/HELP keywords, and data retention. The default `front-door/privacy.html` includes all of these.
- **Opt-in screenshot does not show consent language.** The screenshot must show the SMS consent paragraph on the same screen where the user enters their phone number. The default signup screen since this PR landed satisfies this.
- **Use case category mismatch with sample message.** If the sample message reads "verification code," `ONE_TIME_PASSCODES` or `ACCOUNT_NOTIFICATIONS` are the closest fits; `PROMOTIONS_AND_MARKETING` would be rejected.
- **Volume estimate too high for sole proprietor.** Cabalmail's deployment is low-volume; keep `TFV_MONTHLY_VOLUME=10` unless you actually expect more.
