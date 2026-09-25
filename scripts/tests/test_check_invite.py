'''Unit tests for the check_invite pre-sign-up trigger.

    python3 -m unittest discover -s scripts/tests -p "test_check_invite.py"

Lives here rather than beside the Lambda because build-counter.sh zips
every file under a function directory into the deploy artifact. Pure
stdlib. The handler reads INVITATION_CODE and SMS_ENABLED at import time,
so each test loads a fresh copy of the module under the environment it
wants.
'''

import importlib.util
import os
import unittest
from unittest import mock

_HERE = os.path.dirname(os.path.abspath(__file__))
_FUNCTION = os.path.join(_HERE, '..', '..', 'lambda', 'counter', 'check_invite', 'function.py')


def load(invitation_code='', sms_enabled='true'):
    '''The trigger module, imported under the given environment.'''
    env = {'INVITATION_CODE': invitation_code, 'SMS_ENABLED': sms_enabled}
    with mock.patch.dict(os.environ, env, clear=False):
        spec = importlib.util.spec_from_file_location('check_invite_under_test', _FUNCTION)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    return module


def event(trigger_source, code=None):
    '''A minimal pre-sign-up event, with validation data only when asked.'''
    request = {'userAttributes': {}}
    if code is not None:
        request['validationData'] = {'invitationCode': code}
    return {'triggerSource': trigger_source, 'request': request}


class InvitationGateTests(unittest.TestCase):
    CODE = 'open-sesame'

    def test_signup_with_the_code_passes(self):
        trigger = load(self.CODE)
        out = trigger.handler(event('PreSignUp_SignUp', self.CODE), None)
        self.assertEqual(out['triggerSource'], 'PreSignUp_SignUp')

    def test_signup_without_or_with_wrong_code_is_rejected(self):
        trigger = load(self.CODE)
        with self.assertRaises(trigger.InvalidInvitationCode):
            trigger.handler(event('PreSignUp_SignUp'), None)
        with self.assertRaises(trigger.InvalidInvitationCode):
            trigger.handler(event('PreSignUp_SignUp', 'guess'), None)

    def test_admin_create_is_exempt(self):
        # Terraform's aws_cognito_user (AdminCreateUser) carries no usable
        # validation data; the caller is IAM-authorized, so the gate does
        # not apply.
        trigger = load(self.CODE)
        out = trigger.handler(event('PreSignUp_AdminCreateUser'), None)
        self.assertEqual(out['triggerSource'], 'PreSignUp_AdminCreateUser')

    def test_federated_signup_is_still_gated(self):
        trigger = load(self.CODE)
        with self.assertRaises(trigger.InvalidInvitationCode):
            trigger.handler(event('PreSignUp_ExternalProvider'), None)

    def test_empty_code_disables_the_gate(self):
        trigger = load('')
        out = trigger.handler(event('PreSignUp_SignUp'), None)
        self.assertEqual(out['triggerSource'], 'PreSignUp_SignUp')


class AutoConfirmTests(unittest.TestCase):
    def test_auto_confirms_when_sms_is_off(self):
        trigger = load('', sms_enabled='false')
        out = trigger.handler(event('PreSignUp_SignUp'), None)
        self.assertTrue(out['response']['autoConfirmUser'])

    def test_leaves_confirmation_to_cognito_when_sms_is_on(self):
        trigger = load('', sms_enabled='true')
        out = trigger.handler(event('PreSignUp_SignUp'), None)
        self.assertNotIn('response', out)


if __name__ == '__main__':
    unittest.main()
