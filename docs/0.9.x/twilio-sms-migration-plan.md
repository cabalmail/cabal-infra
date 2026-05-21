# Plan: Replace AWS End User Messaging with Twilio for Cognito SMS

## Goal

Cut Cabalmail loose from AWS's toll-free verification queue by routing all
Cognito SMS (signup verification, password reset, MFA) through Twilio via a
`custom_sms_sender` Lambda trigger. The AWS toll-free number stays (or is
destroyed) - it's not on the SMS path anymore.

## Architecture

```
Cognito event (signup / forgot-password / MFA)
   |
   v
custom_sms_sender Lambda (new)
   |  - decrypts the OTP with KMS
   |  - reads Twilio creds from SSM
   v
Twilio Messages API  -->  user's phone
```

Cognito encrypts the verification code with a customer-managed KMS key and
hands it to the Lambda; the Lambda decrypts, formats the message, and POSTs to
Twilio. SNS is no longer in the path.

## Components to add

1. **Twilio account + number**
   - New Twilio account (or sub-account) with a toll-free or 10DLC US number.
     Toll-free verification at Twilio runs days, not months.
   - A2P registration (brand + campaign) for 10DLC; toll-free verification
     form if going TF. Either way, Cabalmail-grade volume fits in the cheapest
     tier.

2. **Twilio Terraform provider** (`twilio/twilio`, pre-1.0)
   - Pin to a known-good version in `terraform/infra/versions.tf`. Pre-1.0
     means breaking changes between minors - version-pin tight, don't float.
   - Provider auth via env vars in CI (`TWILIO_ACCOUNT_SID`, `TWILIO_API_KEY`,
     `TWILIO_API_SECRET`) added as GitHub Environment secrets per env
     (dev/stage/prod), so each env can have its own subaccount/number if
     desired.
   - Resources: `twilio_messaging_v1_service` (messaging service holding the
     number, recommended over raw `from`), `twilio_messaging_v1_phone_number`
     to attach the number. The number itself may need to be purchased once
     out-of-band and imported - provider coverage of `IncomingPhoneNumbers` is
     uneven; worth a 30-min spike before committing.

3. **New module `terraform/infra/modules/sms_sender/`**
   - `aws_kms_key` for Cognito code encryption (key policy allows
     `cognito-idp.amazonaws.com` to `Encrypt` and the Lambda role to
     `Decrypt`).
   - `aws_ssm_parameter` (SecureString) for Twilio API key/secret, sourced
     from a TF variable wired to a GHA secret. Don't commit, don't echo in
     plan output.
   - `aws_lambda_function` `sms_sender` (Python, in `lambda/sms-sender/`).
     Triggered by Cognito `CustomSMSSender_*` events. Reads SSM at
     cold-start, decrypts code via KMS, sends via Twilio. Returns the event
     unchanged.
   - IAM: `kms:Decrypt` on the key, `ssm:GetParameter` on the two params,
     basic logs.
   - `aws_lambda_permission` granting `cognito-idp.amazonaws.com` invoke
     rights.

4. **`lambda/sms-sender/` (new)**
   - Single `function.py`. Dependencies: `twilio` SDK (small enough to bundle
     in the deploy zip - no layer needed unless we want one).
   - Idempotent on retries - log Twilio message SID for tracing; swallow
     non-retryable Twilio errors so Cognito doesn't loop.
   - Pylint config consistent with `lambda/api/.pylintrc`.

5. **Wire it into the user pool**
   (`terraform/infra/modules/user_pool/main.tf`)

   ```hcl
   lambda_config {
     post_confirmation  = aws_lambda_function.assign_osid.arn
     custom_sms_sender {
       lambda_arn     = var.sms_sender_arn
       lambda_version = "V1_0"
     }
     kms_key_id = var.sms_kms_key_arn   # required when custom_sms_sender is set
   }
   ```

   - Pass `sms_sender_arn` and `sms_kms_key_arn` in as variables from
     `terraform/infra/main.tf`.
   - **Keep `sms_configuration`.** Cognito still validates it exists when SMS
     attributes are auto-verified, even though it isn't called on the hot
     path. The IAM role can stay; the SNS publish permission becomes dead
     weight but harmless.
   - **Remove `aws_pinpointsmsvoicev2_phone_number.sms`** and the
     `sms_phone_number` output. Once the custom sender is live, nothing uses
     it. Doing the removal in a follow-up PR (after verifying Twilio works
     end-to-end) keeps rollback cheap.

6. **CI/secrets plumbing**
   - Add `TWILIO_ACCOUNT_SID`, `TWILIO_API_KEY`, `TWILIO_API_SECRET`,
     `TWILIO_FROM_NUMBER` (or messaging service SID) to each GitHub
     Environment.
   - Extend `app.yml` with a `lambda-sms-sender` job paralleling
     `lambda-counter`: pylint, build zip, `aws lambda update-function-code`.

## Rollout order

1. PR 1 - additive only: new module, Lambda, KMS key, SSM params, Twilio
   provider, Twilio number. **Do not** attach to the user pool yet. Merge
   through stage to prod. Smoke-test the Lambda manually with a synthetic
   Cognito event payload (`aws lambda invoke`).
2. PR 2 - wire `custom_sms_sender` + `kms_key_id` into the user pool in stage
   only (feature flag via a `var.use_twilio_sms` boolean). Test real
   signup/forgot-password on stage.
3. PR 3 - flip the flag on for prod. Ship.
4. PR 4 - cleanup: delete `aws_pinpointsmsvoicev2_phone_number`, drop the
   `sms_phone_number` output, drop the 1-minute timeout hack, and revisit
   whether the SNS IAM role can be simplified.

## Risks / open questions

- **Twilio provider gaps.** Pre-1.0; phone-number purchase may need a
  one-time manual buy + `terraform import`. Worth a short spike before PR 1.
- **`sms_configuration` requirement.** Cognito's API has historically
  required it whenever phone is auto-verified, even alongside
  `custom_sms_sender`. Confirm by reading current Cognito docs (the
  constraint has loosened over time) - if it's now optional, drop it.
- **Cold-start latency.** Twilio API call from cold Lambda adds ~1s to the
  user's first SMS. Acceptable for verification flows; not worth provisioned
  concurrency.
- **Cost.** Twilio toll-free: ~$2/month rental, ~$0.0075/SMS US. Negligible
  at Cabalmail's scale.
- **Per-env numbers.** Decide whether dev/stage share one Twilio number
  (cheap, OK for low volume) or each gets its own (cleaner audit trail).
  Recommend shared subaccount for non-prod, dedicated number for prod.
- **Country coverage.** AWS toll-free was US-only anyway, so no regression.
  If you ever sign up non-US users, Twilio's catalog covers it without the
  EUM ordeal.

## Rollback

Single-knob: flip `use_twilio_sms` back to `false`. The user pool reverts to
the SNS path (and the AWS toll-free number, if not yet destroyed). Worst
case, re-add the `aws_pinpointsmsvoicev2_phone_number` resource -
provisioning still slow, but the door isn't closed.
