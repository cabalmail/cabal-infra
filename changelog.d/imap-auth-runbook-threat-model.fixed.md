- **IMAPAuthFailureSpike runbook and alert text describing a threat that no
  longer exists.** Both told the operator that a spike is most likely an
  internet brute force against the public IMAP listener, and the runbook's
  remediation blocked port 993 at a security group and a NACL — controls that
  have been dead since that listener was removed. The runbook now names the two
  causes that remain (the API Lambdas failing to authenticate, or an unexpected
  in-VPC source attempting logins), points at the task-ENI security group as
  the control surface, and records that a plaintext-dialling consumer locks
  itself out *without* firing this alert. A new unit test pins every port a
  runbook prescribes acting on to a port the mail tiers actually publish.
