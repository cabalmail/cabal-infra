#!/usr/bin/env bash
# Converge the HELP/STOP/START keyword auto-responses on the account's
# 10DLC phone number in AWS End User Messaging.
#
# The keyword texts must match the messages registered with the 10DLC
# campaign (helpMessage / stopMessage), so they are composed from the
# same deployment variables the consent surfaces render from rather
# than hard-coded. Texts are deliberately ASCII-only: they fit the
# GSM-7 SMS character set.
#
# Terraform cannot own these: the AWS provider exposes no keyword
# resource, so this runs as a post-apply step in infra.yml. put-keyword
# is a full overwrite, making this idempotent; steady-state it is a
# no-op rewrite of the same values.
#
# No-op (exit 0) when the account has no 10DLC number yet - the number
# only exists once the campaign registration is approved and its id is
# supplied to Terraform.
set -euo pipefail

for v in OPERATOR_NAME CONTROL_DOMAIN; do
  if [ -z "${!v:-}" ]; then
    echo "[sms-keywords] error: $v is not set" >&2
    exit 1
  fi
done

NUMBER_IDS=$(aws pinpoint-sms-voice-v2 describe-phone-numbers \
  --query "PhoneNumbers[?NumberType=='TEN_DLC'].PhoneNumberId" \
  --output text)

if [ -z "${NUMBER_IDS}" ]; then
  echo "[sms-keywords] no 10DLC phone number in this account; nothing to do"
  exit 0
fi

BRAND="Cabalmail (${OPERATOR_NAME})"
HELP_MSG="${BRAND}: For help, email help@support.${CONTROL_DOMAIN} or visit https://www.${CONTROL_DOMAIN}. Msg frequency varies. Msg & data rates may apply. Reply STOP to cancel."
STOP_MSG="${BRAND}: You are unsubscribed and will receive no further SMS. SMS-based account recovery is disabled. Reply START to resume."
START_MSG="${BRAND}: You are re-subscribed to Cabalmail transactional SMS. Msg frequency varies. Msg & data rates may apply. Reply HELP for help or STOP to cancel."

for id in ${NUMBER_IDS}; do
  echo "[sms-keywords] converging keywords on ${id}"
  aws pinpoint-sms-voice-v2 put-keyword \
    --origination-identity "${id}" \
    --keyword HELP \
    --keyword-message "${HELP_MSG}" \
    --keyword-action AUTOMATIC_RESPONSE >/dev/null
  aws pinpoint-sms-voice-v2 put-keyword \
    --origination-identity "${id}" \
    --keyword STOP \
    --keyword-message "${STOP_MSG}" \
    --keyword-action OPT_OUT >/dev/null
  aws pinpoint-sms-voice-v2 put-keyword \
    --origination-identity "${id}" \
    --keyword START \
    --keyword-message "${START_MSG}" \
    --keyword-action OPT_IN >/dev/null
  echo "[sms-keywords] HELP/STOP/START set on ${id}"
done
