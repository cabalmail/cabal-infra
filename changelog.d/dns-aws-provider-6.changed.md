- **dns bootstrap stack on the aws provider 6.x line.** `terraform/dns`
  pinned `hashicorp/aws ~> 4.0.0`, two majors behind the infra stack; it
  now shares infra's `>= 6.0.0, < 7.0.0` constraint and commits its
  provider lockfile.
