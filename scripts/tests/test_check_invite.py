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


def event(trigger_source, code=None, username='new-user'):
    '''A minimal pre-sign-up event, with validation data only when asked.
    The default username passes the username rule, so the gate tests see
    only the gate.'''
    request = {'userAttributes': {}}
    if code is not None:
        request['validationData'] = {'invitationCode': code}
    return {'triggerSource': trigger_source, 'userName': username, 'request': request}


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

    def test_a_code_with_non_ascii_characters_is_a_wrong_code(self):
        trigger = load(self.CODE)
        with self.assertRaises(trigger.InvalidInvitationCode):
            trigger.handler(event('PreSignUp_SignUp', 'open-s\u00e9same'), None)

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


class UsernameRuleTests(unittest.TestCase):
    '''Self-service usernames: the sign-up screens' shape, at least one
    letter, and none of the names the mail images or aliases already use.'''
    CODE = 'open-sesame'

    def assert_rejected(self, name):
        '''A self-service sign-up with the right code and this name fails
        on the name.'''
        trigger = load(self.CODE)
        with self.assertRaises(trigger.InvalidUsername, msg=name):
            trigger.handler(event('PreSignUp_SignUp', self.CODE, name), None)

    def assert_accepted(self, name):
        '''A self-service sign-up with the right code and this name passes.'''
        trigger = load(self.CODE)
        out = trigger.handler(event('PreSignUp_SignUp', self.CODE, name), None)
        self.assertEqual(out['userName'], name)

    def test_what_the_signup_screens_allow_passes(self):
        for name in ('alice', 'a1c', 'bob-smith', '2fast', 'x' * 32, 'mail-admin'):
            self.assert_accepted(name)

    def test_names_the_mail_images_and_aliases_use_are_reserved(self):
        for name in ('root', 'mail', 'dovecot', 'dovenull', 'nobody', 'users',
                     'wheel', 'opendkim', 'systemd-network', 'postmaster',
                     'support', 'master', 'ci-probe', 'admin'):
            self.assert_rejected(name)

    def test_names_outside_the_signup_shape_are_rejected(self):
        for name in ('ab', 'x' * 33, 'Alice', 'a.b', 'a_b', 'a/b', '..', '-ab',
                     'ab-', 'a*admin', 'a b', '12345', '1-2', '', '\u00e9-user'):
            self.assert_rejected(name)

    def test_a_missing_username_is_rejected(self):
        trigger = load(self.CODE)
        bare = event('PreSignUp_SignUp', self.CODE)
        del bare['userName']
        with self.assertRaises(trigger.InvalidUsername):
            trigger.handler(bare, None)

    def test_username_messages_never_mention_the_invitation_code(self):
        # React shows "Invalid invitation code." for any message matching
        # /invitation code/i, so a username message must not.
        trigger = load(self.CODE)
        for name in ('root', 'A', '123'):
            with self.assertRaises(trigger.InvalidUsername) as ctx:
                trigger.handler(event('PreSignUp_SignUp', self.CODE, name), None)
            self.assertNotRegex(str(ctx.exception), '(?i)invitation code')

    def test_the_invitation_code_is_checked_first(self):
        trigger = load(self.CODE)
        with self.assertRaises(trigger.InvalidInvitationCode):
            trigger.handler(event('PreSignUp_SignUp', 'guess', 'root'), None)

    def test_the_rule_applies_with_the_gate_off(self):
        trigger = load('')
        with self.assertRaises(trigger.InvalidUsername):
            trigger.handler(event('PreSignUp_SignUp', None, 'root'), None)

    def test_federated_signup_is_held_to_the_rule(self):
        trigger = load('')
        with self.assertRaises(trigger.InvalidUsername):
            trigger.handler(event('PreSignUp_ExternalProvider', None, 'Google_123'), None)

    def test_admin_create_is_exempt_so_terraform_service_users_still_apply(self):
        trigger = load(self.CODE)
        for name in ('master', 'dmarc', 'ci-probe'):
            out = trigger.handler(event('PreSignUp_AdminCreateUser', None, name), None)
            self.assertEqual(out['userName'], name)


if __name__ == '__main__':
    unittest.main()
