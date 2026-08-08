//! Cognito `USER_PASSWORD_AUTH`, MFA, and token refresh — hand-rolled JSON
//! POSTs to `cognito-idp.<region>.amazonaws.com`, with no AWS SDK, mirroring
//! the Apple client's `CognitoAuthService`.
//!
//! Lands in Phase 3, work item 2.
