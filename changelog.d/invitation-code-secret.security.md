- **Invitation code kept as an environment secret.** The deploy and
  quiesce workflows now read `TF_VAR_INVITATION_CODE` from an environment
  secret, and fall back to the environment variable of the same name only
  while no secret exists. Operators should move the code to a secret and
  delete the variable.
