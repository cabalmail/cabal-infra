- The stock Amazon Linux 2 NAT bootstrap path: the AL2 AMI lookup, its
  iptables `user_data`, the `use_custom_nat_ami` toggle, and the module's
  `ROLLBACK.md` (superseded by the mode-switch section of `docs/nat.md`).
  Instance-mode NAT always launches from the Image Builder-baked AL2023
  AMI; AL2 (EOL) is gone from the stack entirely.
