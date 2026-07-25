- Apple: **Readable message when the MFA gate blocks sign-in.** A
  sign-in rejected by the server's MFA-enrollment gate surfaced the raw
  Cognito wrapper ("Server error: PreTokenGeneration failed with error
  …", doubled period included). CabalmailKit now strips Cognito's
  Lambda-trigger wrapper from such rejections and the sign-in screen
  shows the trigger's own message verbatim, without the "Server
  error:" prefix.
