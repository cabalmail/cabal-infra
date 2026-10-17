'''Unit tests for the assign_osid post-confirmation trigger.

    python3 -m unittest discover -s scripts/tests -p "test_assign_osid.py"

Lives here rather than beside the Lambda because build-counter.sh zips
every file under a function directory into the deploy artifact. Pure
stdlib: boto3 is faked in sys.modules while the module loads, so the
suite needs no AWS credentials and never touches the network.
'''

import importlib.util
import os
import sys
import types
import unittest
from unittest import mock

_HERE = os.path.dirname(os.path.abspath(__file__))
_FUNCTION = os.path.join(_HERE, '..', '..', 'lambda', 'counter', 'assign_osid', 'function.py')


class _Recorder:
    '''Stands in for every boto3 client the trigger makes, and records calls.'''

    def __init__(self, calls):
        self.calls = calls

    def update_item(self, **kwargs):
        '''The counter increment.'''
        self.calls.append(('dynamodb.update_item', kwargs))
        return {'Attributes': {'osid': {'N': '2001'}}}

    def admin_update_user_attributes(self, **kwargs):
        '''The uid write to Cognito.'''
        self.calls.append(('cognito.admin_update_user_attributes', kwargs))

    def update_service(self, **kwargs):
        '''A mail-tier roll.'''
        self.calls.append(('ecs.update_service', kwargs))

    def get_parameter(self, **kwargs):
        '''The healthcheck ping URL read.'''
        self.calls.append(('ssm.get_parameter', kwargs))
        return {'Parameter': {'Value': ''}}


def load(calls, ping_param=''):
    '''The trigger module, imported against a fake boto3 that appends to calls.'''
    fake = types.ModuleType('boto3')
    fake.client = lambda *_args, **_kwargs: _Recorder(calls)
    env = {
        'AWS_REGION': 'us-east-1',
        'ECS_CLUSTER_NAME': 'cabal',
        'HEALTHCHECK_PING_PARAM': ping_param,
    }
    with mock.patch.dict(sys.modules, {'boto3': fake}), mock.patch.dict(os.environ, env):
        spec = importlib.util.spec_from_file_location('assign_osid_under_test', _FUNCTION)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    return module


def event(trigger_source):
    '''A post-confirmation event in the shape Cognito sends.'''
    return {
        'triggerSource': trigger_source,
        'userPoolId': 'us-east-1_example',
        'userName': 'someone',
        'request': {'userAttributes': {'custom:osid': '1999'}},
        'response': {},
    }


class AssignOsidTest(unittest.TestCase):
    '''A password reset never takes a uid from the counter; a sign-up does.'''

    def setUp(self):
        self.calls = []
        self.trigger = load(self.calls)

    def assert_assigned(self, trigger_source):
        '''The handler took the next uid, stored it and rolled the three tiers.'''
        sent = event(trigger_source)
        self.assertIs(self.trigger.handler(sent, None), sent)
        names = [name for name, _ in self.calls]
        self.assertEqual(names, [
            'dynamodb.update_item',
            'cognito.admin_update_user_attributes',
            'ecs.update_service',
            'ecs.update_service',
            'ecs.update_service',
        ])
        update = self.calls[1][1]
        self.assertEqual(update['Username'], 'someone')
        self.assertEqual(update['UserAttributes'], [{'Name': 'custom:osid', 'Value': '2001'}])

    def test_password_reset_leaves_the_uid_alone(self):
        '''A confirmed password reset writes nothing and rolls nothing.'''
        sent = event('PostConfirmation_ConfirmForgotPassword')
        self.assertIs(self.trigger.handler(sent, None), sent)
        self.assertEqual(self.calls, [])

    def test_password_reset_still_pings_the_heartbeat(self):
        '''The reset path reaches the healthcheck ping and nothing else, which
        is what the cognito-user-sync runbook's manual invoke relies on.'''
        calls = []
        trigger = load(calls, ping_param='/cabal/healthcheck_ping_cognito_user_sync')
        trigger.handler(event('PostConfirmation_ConfirmForgotPassword'), None)
        self.assertEqual([name for name, _ in calls], ['ssm.get_parameter'])

    def test_sign_up_assigns_a_uid_and_rolls_the_mail_tiers(self):
        '''ConfirmSignUp and AdminConfirmSignUp both send this source.'''
        self.assert_assigned('PostConfirmation_ConfirmSignUp')

    def test_other_source_is_treated_as_a_sign_up(self):
        '''AWS doesn't document the source for an auto-confirmed sign-up, so
        anything but a reset still gets a uid rather than none.'''
        self.assert_assigned('PostConfirmation_SomethingNew')


if __name__ == '__main__':
    unittest.main()
