- The admin app now supports the pool's opt-in two-factor authentication
  end to end: a Security view (account menu) enrolls an authenticator app
  via QR code or manual key, and sign-in answers Cognito's TOTP (or SMS)
  challenge with a dedicated code screen. Signup collects a recovery email
  address alongside the phone number and follows Cognito's reported
  delivery channel for the confirmation code, and after sign-in users
  without a verified email are offered a skippable add-and-verify flow, so
  existing SMS-only accounts gain the email recovery fallback without
  being locked out. Password-reset copy now names the channel the code
  was actually sent to (email first, phone fallback).
