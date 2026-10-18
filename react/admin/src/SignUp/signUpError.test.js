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

  it('keeps the generic message for any other failure', () => {
    expect(signUpErrorMessage({ code: 'UsernameExistsException', message: 'User already exists' }))
      .toBe('Registration failed.');
    expect(signUpErrorMessage({ code: 'UserLambdaValidationException', message: '' }))
      .toBe('Registration failed.');
    expect(signUpErrorMessage(null)).toBe('Registration failed.');
  });

  it("keeps the generic message when a later trigger fails", () => {
    expect(signUpErrorMessage({
      code: 'UserLambdaValidationException',
      name: 'UserLambdaValidationException',
      message: 'PostConfirmation failed with error Something went wrong.',
    })).toBe('Registration failed.');
  });
});
