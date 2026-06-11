- NAT instances and NAT Gateways are now two first-class egress modes,
  selected per environment via `TF_VAR_USE_NAT_INSTANCE` (default `true`,
  matching the existing instance mode). A new instance-mode environment
  bootstraps through a NAT Gateway: apply once in gateway mode, build the
  first AL2023 NAT AMI through it (the Image Builder pipeline is now gated
  on its own `TF_VAR_BUILD_NAT_AMI` flag, independent of the egress mode),
  then flip to instances. Both modes share the same Elastic IPs, so
  `smtp.<control-domain>`, SPF, and the port-25 allow-list are unaffected
  by the mode choice. See `docs/nat.md`.
