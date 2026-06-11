- The quiesce workflow now passes `sinkhole`, `use_eum_sms`, and the
  invitation code through to Terraform the same way `infra.yml` does.
  Its tfvars block previously fell back to the variable defaults, so a
  quiesce apply tried to release the deletion-protected EUM phone
  number (observed failing on development), and a stage quiesce would
  have silently destroyed the sinkhole tier and blanked the
  `check_invite` invitation code.
