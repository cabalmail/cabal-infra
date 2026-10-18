'''Cognito pre-signup trigger that gates signups on a shared invitation code
and on the shape of the username.

Compares the `invitationCode` validation-data value supplied by the client
against the INVITATION_CODE env var. When INVITATION_CODE is empty (the
default) the check is disabled and every signup is allowed through.

The gate exists to keep strangers from self-registering through the public
app client. It does not apply to AdminCreateUser: Cognito invokes this
trigger for that path too (triggerSource PreSignUp_AdminCreateUser), but
the caller has already been authorized by IAM. Terraform cannot satisfy the
check anyway: the AWS provider normalizes aws_cognito_user validation_data
keys the way it normalizes user attributes, so `invitationCode` arrives here
as `custom:invitationCode`. Without the exemption Terraform cannot create a
system user (master, dmarc, ci-probe) once this code is deployed with the
code set. The bootstrap placeholder (check_invite.tf) is a no-op, so a
one-shot fresh apply gets past it; bring-ups are rarely one-shot.

The username check has the same exemption. The username becomes the
user's OS login name on the mail tiers (docker/shared/sync-users.sh), the
local recipient every one of their addresses maps to, and their Dovecot
login, so it has to be a name those can all take as it is. A self-service
username must have the shape the sign-up screens ask for (3-32 lowercase
letters, digits and hyphens, no leading or trailing hyphen), must contain
a letter (a login name is never all digits), and must not be a name the
mail images' own accounts, groups or sendmail aliases already use. No
underscore: generate-config.sh names the alias for an address shared by
several users by joining their usernames with `_`.

When SMS_ENABLED is not "true", the pool has no SMS delivery path
configured (see issue #712 and terraform/infra/modules/user_pool/main.tf),
so the trigger auto-confirms the user in-Lambda: without this the account
would sit UNCONFIRMED and the client would fall through to a Cognito
verification step that has no channel to deliver on.
'''
import os
import hmac
import re

expected_code = os.environ.get('INVITATION_CODE', '')
sms_enabled = os.environ.get('SMS_ENABLED', '').lower() == 'true'

# The one trigger source the invitation gate exempts. Self-service signup is
# PreSignUp_SignUp; federated signup is PreSignUp_ExternalProvider.
ADMIN_CREATE = 'PreSignUp_AdminCreateUser'

# The sign-up screens' rule (react/admin/src/SignUp/index.jsx usernameValid).
USERNAME_SHAPE = re.compile(r'[a-z0-9][a-z0-9-]{1,30}[a-z0-9]')

# Names a self-service user may not take. Three sources, kept in this order
# so a reviewer can diff each against where it comes from:
#   1. the left-hand sides of docker/shared/aliases.static, plus root;
#   2. accounts and groups the amazonlinux:2023 mail images ship (the base
#      `setup` package plus dovecot, sendmail, opendkim, opendmarc, systemd)
#      - a snapshot: refresh it when an image gains a package that adds an
#      account or group;
#   3. the Terraform-created service users (modules/app/*_user.tf), listed
#      so they stay reserved in a pool that has not created them yet, and
#      admin, the Dovecot master user the API logs in through
#      ({user}*admin).
# Names outside USERNAME_SHAPE (ssh_keys, ...) need no entry.
RESERVED_USERNAMES = frozenset('''
    mailer-daemon postmaster bin daemon adm lp sync shutdown halt mail news
    uucp operator games gopher ftp nobody radiusd nut dbus vcsa canna wnn
    rpm nscd pcap apache webalizer dovecot fax quagga radvd pvm amanda
    privoxy ident named xfs gdm mailnull postgres sshd smmsp postfix
    netdump ldap squid ntp mysql desktop rpcuser rpc nfsnobody ingres system
    toor manager dumper abuse newsadm newsadmin usenet ftpadm ftpadmin
    ftp-adm ftp-admin www webmaster noc security hostmaster info marketing
    sales support decode root

    sys tty disk mem kmem wheel cdrom man dialout floppy tape video lock
    audio users utmp utempter input kvm render sgx tss dovenull opendkim
    opendmarc polkitd chrony

    master dmarc ci-probe admin
'''.split())
RESERVED_PREFIXES = ('systemd-',)


class InvalidInvitationCode(Exception):
    '''Raised when the supplied invitation code does not match the shared
    secret. Cognito surfaces the message verbatim to the client as a
    UserLambdaValidationException.'''


class InvalidUsername(Exception):
    '''Raised when a self-service username cannot be a mail account. Cognito
    surfaces the message to the client as a UserLambdaValidationException
    ("PreSignUp failed with error <message>."), which the Apple and Android
    clients unwrap and React shows; it must not mention the invitation code,
    which React matches on.'''


def username_problem(username):
    '''Why `username` cannot be a self-service account, or None.'''
    if not USERNAME_SHAPE.fullmatch(username or ''):
        return ('Usernames are 3 to 32 lowercase letters, numbers and hyphens, '
                'and cannot start or end with a hyphen.')
    if not re.search('[a-z]', username):
        return 'Usernames must contain at least one letter.'
    if username in RESERVED_USERNAMES or username.startswith(RESERVED_PREFIXES):
        return 'That username is reserved. Choose another.'
    return None


def handler(event, _context):
    '''Pre-sign-up Cognito trigger: reject signups missing the shared code
    or choosing an unusable username (admin-created users excepted), and
    auto-confirm the user when SMS is off (no delivery channel exists to
    complete the default self-serve confirmation).'''
    if event.get('triggerSource') != ADMIN_CREATE:
        if expected_code:
            validation_data = (event.get('request') or {}).get('validationData') or {}
            supplied = validation_data.get('invitationCode', '')
            # Bytes, not str: compare_digest refuses a str with non-ASCII
            # characters, and a code like that is simply a wrong one.
            if not hmac.compare_digest(supplied.encode('utf-8'),
                                       expected_code.encode('utf-8')):
                raise InvalidInvitationCode('Invalid invitation code.')
        problem = username_problem(event.get('userName'))
        if problem:
            raise InvalidUsername(problem)
    if not sms_enabled:
        response = event.setdefault('response', {})
        response['autoConfirmUser'] = True
    return event
