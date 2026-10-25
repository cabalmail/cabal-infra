import { describe, it, expect } from 'vitest';
import { signUpErrorMessage } from './signUpError';

const triggerError = (message) => ({
  code: 'UserLambdaValidationException',
  name: 'UserLambdaValidationException',
  message: `PreSignUp failed with error ${message}.`,
});

describe('signUpErrorMessage', () => {
  it('names a wrong invitation code', () => {
    expect(signUpErrorMessage(triggerError('Invalid invitation code.')))
      .toBe('Invalid invitation code.');
  });

  it("shows the trigger's own reason for a username it refuses", () => {
    expect(signUpErrorMessage(triggerError('That username is reserved. Choose another.')))
      .toBe('That username is reserved. Choose another.');
    expect(signUpErrorMessage(triggerError('Usernames must contain at least one letter.')))
      .toBe('Usernames must contain at least one letter.');
  });

  // Issue #2141: everything but an invitation-code refusal read as the bare
  // "Registration failed.", so a sign-up turned away for its phone number or
  // its password left the user with no idea which field to fix. These are
  // the live messages the verification pass read off Cognito.
  it('names the field when Cognito refuses a phone number', () => {
    expect(signUpErrorMessage({
      code: 'InvalidParameterException',
      message: 'Invalid phone number format.',
    })).toBe('Invalid phone number format.');
  });

  it('shows which part of the password policy failed', () => {
    expect(signUpErrorMessage({
      code: 'InvalidPasswordException',
      message: 'Password did not conform with policy: Password must have uppercase characters',
    })).toBe('Password must have uppercase characters.');
  });

  it('passes a refusal with no policy clause through whole', () => {
    // The compromised-credentials check, which the verification pass found
    // runs before the character-class policy.
    expect(signUpErrorMessage({
      code: 'InvalidPasswordException',
      message: 'Provided password cannot be used for security reasons.',
    })).toBe('Provided password cannot be used for security reasons.');
  });

  it('names a username already taken', () => {
    expect(signUpErrorMessage({
      code: 'UsernameExistsException',
      message: 'User already exists',
    })).toBe('That username is taken. Choose another.');
  });

  it('names a rate limit without quoting Cognito at the user', () => {
    for (const code of [
      'LimitExceededException', 'TooManyRequestsException', 'TooManyFailedAttemptsException',
    ]) {
      expect(signUpErrorMessage({ code, message: 'Attempt limit exceeded' }))
        .toBe('Too many attempts. Please try again later.');
    }
  });

  it('keeps the generic message for any other failure', () => {
    expect(signUpErrorMessage({ code: 'NotAuthorizedException', message: 'nope' }))
      .toBe('Registration failed.');
    expect(signUpErrorMessage({ code: 'UserLambdaValidationException', message: '' }))
      .toBe('Registration failed.');
    expect(signUpErrorMessage(null)).toBe('Registration failed.');
  });

  it('keeps the generic message when a named refusal arrives empty', () => {
    // Nothing to show is not an empty banner.
    expect(signUpErrorMessage({ code: 'InvalidParameterException', message: '   ' }))
      .toBe('Registration failed.');
    expect(signUpErrorMessage({ code: 'InvalidPasswordException', message: '' }))
      .toBe('Registration failed.');
  });

  it("keeps the generic message when a later trigger fails", () => {
    expect(signUpErrorMessage({
      code: 'UserLambdaValidationException',
      name: 'UserLambdaValidationException',
      message: 'PostConfirmation failed with error Something went wrong.',
    })).toBe('Registration failed.');
  });
});
