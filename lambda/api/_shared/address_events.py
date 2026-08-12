'''The address-changed fan-out the mail containers listen for.

Every handler that mutates a `cabal-addresses` row publishes this event so
docker/shared/reconfigure.sh (SQS-subscribed to the topic) re-runs
generate-config.sh immediately instead of waiting for its periodic fallback
regenerate.

Deliberately depends on only boto3 (provided by the Lambda runtime) and the
standard library, for the same reason as admin_limits.py: the publishers are a
mix of user endpoints (new, revoke) and admin ones (assign_address,
unassign_address, new_address_admin), and two of them ship an empty
requirements.txt. Living in helper.py would drag imapclient / dnspython, plus
helper's module-load master-password fetch, into zips that carry neither.
'''
import json
import os
from datetime import datetime, timezone
import boto3  # pylint: disable=import-error

address_changed_topic_arn = os.environ.get('ADDRESS_CHANGED_TOPIC_ARN', '')

sns = boto3.client('sns')


def notify_containers():
    '''Publishes an address change event to SNS'''
    if not address_changed_topic_arn:
        print('ADDRESS_CHANGED_TOPIC_ARN not set, skipping SNS publish')
        return
    sns.publish(
        TopicArn=address_changed_topic_arn,
        Message=json.dumps({
            'event': 'address_changed',
            'timestamp': datetime.now(timezone.utc).isoformat()
        })
    )
