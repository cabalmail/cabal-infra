/**
* Per-tier configuration used by for_each resources (SQS, security groups,
* log groups). Task definitions and services remain explicit because the
* tier-specific differences (EFS mounts, secrets, deployment constraints)
* make a for_each approach less readable.
*/

locals {
  tiers = {
    imap = {
      public_ports  = [143, 993]
      private_ports = [25]
    }
    smtp-in = {
      public_ports  = [25]
      private_ports = []
    }
    smtp-out = {
      public_ports  = [25, 587]
      private_ports = []
    }
  }

  # Target groups are keyed by function, not tier, because smtp-out
  # maps to two target groups (submission + starttls).
  target_groups = {
    imap       = { port = 143 }
    relay      = { port = 25 }
    submission = { port = 25 }
    starttls   = { port = 587 }
  }

  # Flatten per-tier port lists into a map keyed by "tier-port" for
  # use with for_each on security group ingress rules.
  public_ingress = merge([
    for tier, cfg in local.tiers : {
      for port in cfg.public_ports : "${tier}-${port}" => {
        tier = tier
        port = port
      }
    }
  ]...)

  private_ingress = merge([
    for tier, cfg in local.tiers : {
      for port in cfg.private_ports : "${tier}-${port}" => {
        tier = tier
        port = port
      }
    }
  ]...)
}
