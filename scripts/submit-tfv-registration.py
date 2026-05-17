#!/usr/bin/env python3
"""Submit (or resume) an AWS End User Messaging US toll-free verification.

The Cabalmail EUM phone number is provisioned by Terraform but sits in
"Pending" forever until a US_TOLL_FREE_REGISTRATION is created, populated,
associated with the number, and submitted. AWS does not surface this
requirement anywhere in the console flow; the number just waits.

This script drives the API end-to-end and is idempotent on re-run:

  1. Look up (or accept via env) the toll-free PhoneNumberId.
  2. Find an existing US_TOLL_FREE_REGISTRATION associated with that
     number; if none exists, create one.
  3. Upload the opt-in screenshot as a registration attachment.
  4. Set every required field via put-registration-field-value.
  5. Associate the registration with the phone number (no-op if already).
  6. Submit the latest registration version.

Re-running the script after a REQUIRES_UPDATES rejection picks up the
existing registration, re-applies field values (so a field correction
in env vars takes effect), and re-submits.

Required env vars (mirrors GitHub Environment variables added by docs/sms-tfv-setup.md):

  AWS_REGION                       e.g. us-east-1
  TFV_COMPANY_NAME                 Legal entity name on file
  TFV_COMPANY_WEBSITE              https://www.<control_domain> (the front door site)
  TFV_COMPANY_ADDRESS1             Street address line 1
  TFV_COMPANY_CITY
  TFV_COMPANY_STATE                Two-letter state code (US) or province
  TFV_COMPANY_ZIP                  ZIP / postal code
  TFV_CONTACT_FIRST_NAME           Support contact first name
  TFV_CONTACT_LAST_NAME            Support contact last name
  TFV_CONTACT_EMAIL                Support contact email
  TFV_CONTACT_PHONE                Support contact phone (E.164, e.g. +15551234567)
  TFV_OPT_IN_IMAGE                 Path to opt-in screenshot file (PNG or JPG)

Optional env vars:

  TFV_COMPANY_ADDRESS2             Street address line 2 (suite, unit)
  TFV_COMPANY_COUNTRY              ISO country code, default US
  TFV_MONTHLY_VOLUME               Default "10" (low-volume hobby project)
  TFV_USE_CASE_CATEGORY            Default "Two-factor authentication"
  TFV_USE_CASE_DETAILS             Free text; script supplies a sensible default
  TFV_OPT_IN_DESCRIPTION           Free text; script supplies a sensible default
  TFV_SAMPLE_MESSAGE               Free text; defaults to what the sms_sender Lambda actually sends
  TFV_PHONE_NUMBER_ID              Explicit phone-number id-XXXX; if unset the script discovers it

The script does NOT touch any other state and will not delete or change
field values on registrations that are already in REVIEWING or COMPLETE
status. Run it once after provisioning a fresh number, and again after
any REQUIRES_UPDATES so it can replay your env-var corrections.
"""

import os
import sys
import time
import boto3
from botocore.exceptions import ClientError


REGISTRATION_TYPE = "US_TOLL_FREE_REGISTRATION"

# These mirror what lambda/sms-sender/function.py composes. If the
# Lambda copy changes, update this so the registered sample matches
# what the user actually receives - otherwise carriers reject.
DEFAULT_SAMPLE_MESSAGE = "Your Cabalmail verification code is 123456"

DEFAULT_USE_CASE_DETAILS = (
    "Cabalmail is a self-hosted email service. SMS is sent only for "
    "transactional account events that the end user themselves "
    "initiated: a one-time numeric code at signup to verify phone "
    "ownership, a one-time numeric code on password reset, and a "
    "one-time numeric code on sign-in when MFA is enabled. No "
    "promotional or marketing messages. Frequency is event-driven, "
    "typically one message per signup and zero or more on subsequent "
    "password resets."
)

DEFAULT_OPT_IN_DESCRIPTION = (
    "End users opt in during account creation. The signup form (shown "
    "in the attached screenshot) requires the user to enter a mobile "
    "phone number and click 'Create account', a button that is "
    "labelled with text stating that creating an account constitutes "
    "consent to receive transactional SMS for signup verification, "
    "password reset, and sign-in codes, and that the user can reply "
    "STOP at any time. The privacy policy linked from the same "
    "screen describes the same opt-in scope. Users who do not wish "
    "to receive SMS do not create an account; SMS cannot be sent "
    "without a verified phone number on file."
)


def env(name, default=None, required=False):
    """Read an env var, optionally enforcing presence."""
    value = os.environ.get(name, default)
    if required and not value:
        sys.exit(f"error: required env var {name} is not set")
    return value


def discover_phone_number_id(client):
    """Find a US toll-free phone number on the account.

    Returns the PhoneNumberId. Errors if zero or more than one is
    present so the operator chooses explicitly via TFV_PHONE_NUMBER_ID.
    """
    paginator = client.get_paginator("describe_phone_numbers")
    candidates = []
    for page in paginator.paginate(
        Filters=[
            {"Name": "iso-country-code", "Values": ["US"]},
            {"Name": "number-type", "Values": ["TOLL_FREE"]},
        ]
    ):
        candidates.extend(page.get("PhoneNumbers", []))
    if not candidates:
        sys.exit(
            "error: no US toll-free phone numbers found on this account. "
            "Provision one via Terraform (set TF_VAR_USE_EUM_SMS=true) "
            "before running this script."
        )
    if len(candidates) > 1:
        ids = ", ".join(p["PhoneNumberId"] for p in candidates)
        sys.exit(
            "error: multiple US toll-free phone numbers found "
            f"({ids}); set TFV_PHONE_NUMBER_ID explicitly to choose one."
        )
    pn = candidates[0]
    print(
        f"[discover] phone number: {pn['PhoneNumber']} "
        f"({pn['PhoneNumberId']}, status={pn['Status']})"
    )
    return pn["PhoneNumberId"]


def find_existing_registration(client, phone_number_id):
    """Return an existing US_TOLL_FREE_REGISTRATION id linked to the
    phone number, or None.

    Walks describe-registrations filtered by registration type, then
    checks each for an association with the target phone number. Cheap
    in practice because an account typically has at most one TFV.
    """
    paginator = client.get_paginator("describe_registrations")
    for page in paginator.paginate(
        Filters=[
            {"Name": "registration-type", "Values": [REGISTRATION_TYPE]},
        ]
    ):
        for reg in page.get("Registrations", []):
            reg_id = reg["RegistrationId"]
            assocs = client.list_registration_associations(
                RegistrationId=reg_id
            ).get("RegistrationAssociations", [])
            for a in assocs:
                if a.get("ResourceId") == phone_number_id:
                    print(
                        f"[lookup] existing registration: {reg_id} "
                        f"(status={reg['RegistrationStatus']})"
                    )
                    return reg_id, reg["RegistrationStatus"]
    return None, None


def create_registration(client):
    """Create a fresh US_TOLL_FREE_REGISTRATION and return its id."""
    resp = client.create_registration(RegistrationType=REGISTRATION_TYPE)
    reg_id = resp["RegistrationId"]
    print(f"[create] created registration {reg_id}")
    return reg_id


def upload_opt_in_image(client, reg_id, image_path):
    """Upload the opt-in screenshot, return RegistrationAttachmentId."""
    with open(image_path, "rb") as fh:
        body = fh.read()
    resp = client.create_registration_attachment(
        AttachmentBody=body,
        Tags=[{"Key": "Purpose", "Value": "tfv-opt-in"}],
    )
    att_id = resp["RegistrationAttachmentId"]
    print(f"[attach] uploaded opt-in image: {att_id} ({len(body)} bytes)")
    return att_id


def put_text(client, reg_id, field, value):
    """Set a text field on the current draft version."""
    client.put_registration_field_value(
        RegistrationId=reg_id,
        FieldPath=field,
        TextValue=value,
    )
    print(f"[field] {field} = <text:{len(value)} chars>")


def put_choice(client, reg_id, field, value):
    """Set a single-choice field on the current draft version."""
    client.put_registration_field_value(
        RegistrationId=reg_id,
        FieldPath=field,
        SelectChoices=[value],
    )
    print(f"[field] {field} = {value}")


def put_attachment(client, reg_id, field, attachment_id):
    """Bind a previously-uploaded attachment to a field."""
    client.put_registration_field_value(
        RegistrationId=reg_id,
        FieldPath=field,
        RegistrationAttachmentId=attachment_id,
    )
    print(f"[field] {field} = attachment:{attachment_id}")


def associate_phone_number(client, reg_id, phone_number_id):
    """Idempotently associate the phone number with the registration."""
    try:
        client.create_registration_association(
            RegistrationId=reg_id,
            ResourceId=phone_number_id,
        )
        print(f"[assoc] associated {phone_number_id} -> {reg_id}")
    except ClientError as err:
        code = err.response.get("Error", {}).get("Code", "")
        if code == "ConflictException":
            print(f"[assoc] {phone_number_id} already associated, skipping")
        else:
            raise


def submit(client, reg_id):
    """Submit the latest version of the registration for review."""
    resp = client.submit_registration_version(RegistrationId=reg_id)
    print(
        f"[submit] submitted version {resp.get('VersionNumber', '?')} "
        f"(status={resp.get('RegistrationVersionStatus', '?')})"
    )


def main():
    region = env("AWS_REGION", required=True)
    client = boto3.client("pinpoint-sms-voice-v2", region_name=region)

    # Required identity fields. We fail loud on first missing one
    # rather than collecting all errors at once - typically once the
    # operator wires up one, they will wire up the rest from the same
    # source, so progressive validation is more useful.
    fields_text = {
        "companyInfo.companyName":       env("TFV_COMPANY_NAME",      required=True),
        "companyInfo.website":           env("TFV_COMPANY_WEBSITE",   required=True),
        "companyInfo.address1":          env("TFV_COMPANY_ADDRESS1",  required=True),
        "companyInfo.city":              env("TFV_COMPANY_CITY",      required=True),
        "companyInfo.state":             env("TFV_COMPANY_STATE",     required=True),
        "companyInfo.zipCode":           env("TFV_COMPANY_ZIP",       required=True),
        "companyInfo.isoCountryCode":    env("TFV_COMPANY_COUNTRY",   default="US"),
        "contactInfo.firstName":         env("TFV_CONTACT_FIRST_NAME", required=True),
        "contactInfo.lastName":          env("TFV_CONTACT_LAST_NAME",  required=True),
        "contactInfo.supportEmail":      env("TFV_CONTACT_EMAIL",      required=True),
        "contactInfo.supportPhoneNumber": env("TFV_CONTACT_PHONE",     required=True),
        "messagingUseCase.useCaseDetails":    env("TFV_USE_CASE_DETAILS",    default=DEFAULT_USE_CASE_DETAILS),
        "messagingUseCase.optInDescription":  env("TFV_OPT_IN_DESCRIPTION",  default=DEFAULT_OPT_IN_DESCRIPTION),
        "messageSamples.messageSample1":      env("TFV_SAMPLE_MESSAGE",      default=DEFAULT_SAMPLE_MESSAGE),
    }
    address2 = env("TFV_COMPANY_ADDRESS2")
    if address2:
        fields_text["companyInfo.address2"] = address2

    fields_choice = {
        "messagingUseCase.monthlyMessageVolume": env("TFV_MONTHLY_VOLUME",    default="10"),
        "messagingUseCase.useCaseCategory":      env("TFV_USE_CASE_CATEGORY", default="Two-factor authentication"),
    }

    image_path = env("TFV_OPT_IN_IMAGE", required=True)
    if not os.path.isfile(image_path):
        sys.exit(f"error: TFV_OPT_IN_IMAGE path does not exist: {image_path}")

    # 1. Find the phone number
    phone_number_id = env("TFV_PHONE_NUMBER_ID")
    if not phone_number_id:
        phone_number_id = discover_phone_number_id(client)

    # 2. Find or create the registration
    reg_id, status = find_existing_registration(client, phone_number_id)
    if reg_id is None:
        reg_id = create_registration(client)
    elif status in ("REVIEWING", "COMPLETE"):
        sys.exit(
            f"error: registration {reg_id} is in status {status}; cannot "
            "modify or resubmit. Wait for the review to complete (or "
            "return as REQUIRES_UPDATES) before re-running this script."
        )

    # 3. Upload opt-in image (uploaded fresh each run - cheap, ensures
    # the attached file matches the current signup screen).
    attachment_id = upload_opt_in_image(client, reg_id, image_path)

    # 4. Set every field
    for field, value in fields_text.items():
        put_text(client, reg_id, field, value)
    for field, value in fields_choice.items():
        put_choice(client, reg_id, field, value)
    put_attachment(client, reg_id, "messagingUseCase.optInImage", attachment_id)

    # 5. Associate the phone number (no-op if already linked)
    associate_phone_number(client, reg_id, phone_number_id)

    # 6. Submit. A brief delay gives put-registration-field-value time
    # to propagate; AWS occasionally reports MISSING_FIELDS otherwise.
    time.sleep(2)
    submit(client, reg_id)

    print()
    print(f"Registration {reg_id} submitted. Track status with:")
    print(
        f"  aws pinpoint-sms-voice-v2 describe-registrations "
        f"--registration-ids {reg_id} --region {region}"
    )
    print("Carrier review typically takes 5-15 business days.")


if __name__ == "__main__":
    main()
