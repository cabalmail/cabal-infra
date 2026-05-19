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
  TFV_USE_CASE_CATEGORY            Default "ONE_TIME_PASSCODES" (must be one of
                                   the SCREAMING_SNAKE_CASE enum values AWS returns
                                   from describe-registration-field-definitions;
                                   the script logs every valid option at startup)
  TFV_BUSINESS_TYPE                Default "PRIVATE_PROFIT" (right for an LLC or
                                   private corporation). Allowed values:
                                   PRIVATE_PROFIT, PUBLIC_PROFIT, NON_PROFIT,
                                   SOLE_PROPRIETOR, GOVERNMENT
  TFV_OPT_IN_TYPE                  Default "DIGITAL_FORM" (right for a web signup
                                   form). Allowed values: VERBAL, DIGITAL_FORM,
                                   PAPER_FORM, TEXT, QR_CODE
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
    "End users opt in at signup by entering a mobile phone number on "
    "the form in the attached screenshot. The Create account button "
    "label states that account creation constitutes consent to receive "
    "transactional SMS for signup verification, password reset, and "
    "sign-in codes, with STOP to opt out. The linked privacy policy "
    "describes the same scope."
)


def env(name, default=None, required=False):
    """Read an env var, optionally enforcing presence.

    Empty strings are treated as missing. GitHub Actions substitutes
    `${{ vars.FOO }}` with an empty string when `vars.FOO` is unset
    rather than leaving the env var unset, so os.environ.get(name,
    default) returns "" instead of the default for an unset GHA var.
    Coercing empty strings to the default fixes that asymmetry and
    matches what the AWS pinpoint-sms-voice-v2 API actually accepts
    (it rejects TextValue="" at parameter validation, before the
    request ever hits the service).
    """
    value = os.environ.get(name, "") or default
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


def create_registration_version(client, reg_id):
    """Open a new draft version on an existing registration so field
    values can be edited.

    A registration in REQUIRES_UPDATES status has a rejected (frozen)
    most-recent version. PutRegistrationFieldValue against the frozen
    version errors with ConflictException
    EDIT_REGISTRATION_FIELD_VALUES_NOT_ALLOWED. Calling
    CreateRegistrationVersion produces a fresh draft that inherits
    the prior version's field values; subsequent
    PutRegistrationFieldValue calls land on the new draft.
    """
    resp = client.create_registration_version(RegistrationId=reg_id)
    version = resp.get("VersionNumber", "?")
    print(f"[version] opened draft version {version} on {reg_id}")


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


def fetch_field_definitions(client):
    """Fetch the registration's field definitions from AWS and log
    every field's constraints. Returns a dict mapping FieldPath
    (e.g. "messagingUseCase.optInDescription") to its definition.

    Server-side validation rules (max length, allowed choice values,
    regex patterns) are not documented anywhere stable; they live in
    this API. Logging them up-front means any future validation
    failure is one workflow-log lookup away from a diagnosis instead
    of an opaque INVALID_PARAMETER error.
    """
    defs = {}
    paginator = client.get_paginator("describe_registration_field_definitions")
    for page in paginator.paginate(RegistrationType=REGISTRATION_TYPE):
        for d in page.get("RegistrationFieldDefinitions", []):
            path = d.get("FieldPath", "")
            defs[path] = d
            parts = [d.get("FieldType", "?")]
            if d.get("FieldRequirement") == "REQUIRED":
                parts.append("required")
            tv = d.get("TextValidation") or {}
            if "MinLength" in tv:
                parts.append(f"min={tv['MinLength']}")
            if "MaxLength" in tv:
                parts.append(f"max={tv['MaxLength']}")
            sv = d.get("SelectValidation") or {}
            if sv.get("Options"):
                parts.append(f"options={sv['Options']}")
            print(f"[defs] {path}: {' '.join(parts)}")
    return defs


def check_text(defs, field, value):
    """Validate a text value against the field's constraints. Returns
    an error string on violation, or None on success. Centralizes
    the per-field rules so the caller can accumulate errors across
    all fields and surface them together.
    """
    d = defs.get(field)
    if not d:
        return None
    tv = d.get("TextValidation") or {}
    n = len(value)
    if "MaxLength" in tv and n > tv["MaxLength"]:
        return (
            f"{field}: value is {n} chars, exceeds AWS max of "
            f"{tv['MaxLength']}. Shorten the env var or the in-script "
            "default."
        )
    if "MinLength" in tv and n < tv["MinLength"]:
        return (
            f"{field}: value is {n} chars, below AWS min of "
            f"{tv['MinLength']}. Lengthen the env var or the in-script "
            "default."
        )
    return None


def check_choice(defs, field, value):
    """Validate a choice value against the field's allowed Options.
    Returns an error string on violation, or None on success.
    """
    d = defs.get(field)
    if not d:
        return None
    sv = d.get("SelectValidation") or {}
    opts = sv.get("Options") or []
    if opts and value not in opts:
        return (
            f"{field}: value '{value}' is not in AWS options "
            f"{opts}. Set the corresponding env var to one of those."
        )
    return None


def check_required_coverage(defs, fields_we_set):
    """Verify every field AWS marks as REQUIRED is in fields_we_set.

    check_text and check_choice only validate the values we send.
    They cannot catch fields we *don't* send but AWS *requires*; those
    slip past submission and surface later as "missing field" issues
    on the registration once a carrier reviewer looks at it. This
    function closes that gap: if AWS adds a required field tomorrow,
    the next workflow run fails the validation pass with a clear
    "missing required fields: X, Y" message before any API mutation.

    Returns an error string when fields are missing, None otherwise.
    """
    required = {
        path for path, d in defs.items()
        if d.get("FieldRequirement") == "REQUIRED"
    }
    missing = sorted(required - set(fields_we_set))
    if not missing:
        return None
    return (
        f"missing required fields: {', '.join(missing)}. "
        "Add each to fields_text, fields_choice, or as an attachment "
        "in main() with a sensible default and an env-var override."
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
        "messagingUseCase.useCaseCategory":      env("TFV_USE_CASE_CATEGORY", default="ONE_TIME_PASSCODES"),
        "companyInfo.businessType":              env("TFV_BUSINESS_TYPE",     default="PRIVATE_PROFIT"),
        "messagingUseCase.optInType":            env("TFV_OPT_IN_TYPE",       default="DIGITAL_FORM"),
    }

    image_path = env("TFV_OPT_IN_IMAGE", required=True)
    if not os.path.isfile(image_path):
        sys.exit(f"error: TFV_OPT_IN_IMAGE path does not exist: {image_path}")

    # 1. Fetch field definitions up front so every constraint is in
    # the workflow log and we can validate values client-side before
    # the API rejects them with an opaque INVALID_PARAMETER.
    defs = fetch_field_definitions(client)

    # 2. Find the phone number
    phone_number_id = env("TFV_PHONE_NUMBER_ID")
    if not phone_number_id:
        phone_number_id = discover_phone_number_id(client)

    # 3. Find or create the registration. Status drives the next move:
    #   - none           -> create from scratch
    #   - DRAFT          -> edit the existing draft (normal re-run case)
    #   - REQUIRES_UPDATES -> open a fresh draft version; the rejected
    #                        version is frozen and PutRegistrationFieldValue
    #                        on it errors with ConflictException
    #                        EDIT_REGISTRATION_FIELD_VALUES_NOT_ALLOWED.
    #   - anything else  -> exit. SUBMITTED / REVIEWING / COMPLETE / CLOSED
    #                       are non-editable states; the operator should
    #                       wait for AWS to flip status before re-running.
    reg_id, status = find_existing_registration(client, phone_number_id)
    if reg_id is None:
        reg_id = create_registration(client)
    elif status == "DRAFT":
        pass
    elif status == "REQUIRES_UPDATES":
        create_registration_version(client, reg_id)
    else:
        sys.exit(
            f"error: registration {reg_id} is in status {status}; cannot "
            "modify or resubmit. Wait for the review to complete (or "
            "return as REQUIRES_UPDATES) before re-running this script."
        )

    # 4. Upload opt-in image (uploaded fresh each run - cheap, ensures
    # the attached file matches the current signup screen).
    attachment_id = upload_opt_in_image(client, reg_id, image_path)

    # 5. Validate every value against the fetched definitions, plus
    # check that we're setting every REQUIRED field at all. Validation
    # runs as a single pass first so the operator sees every violation
    # in one workflow run rather than discovering them one network
    # round-trip at a time. messagingUseCase.optInImage is set via
    # put_attachment() rather than put_text/put_choice; it's included
    # in the fields_we_set list so the coverage check doesn't false-
    # positive on it.
    fields_we_set = (
        set(fields_text.keys())
        | set(fields_choice.keys())
        | {"messagingUseCase.optInImage"}
    )
    errors = []
    for field, value in fields_text.items():
        err = check_text(defs, field, value)
        if err:
            errors.append(err)
    for field, value in fields_choice.items():
        err = check_choice(defs, field, value)
        if err:
            errors.append(err)
    coverage_err = check_required_coverage(defs, fields_we_set)
    if coverage_err:
        errors.append(coverage_err)
    if errors:
        print()
        print("Validation failed against AWS field definitions:")
        for e in errors:
            print(f"  - {e}")
        sys.exit(1)

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
