- A "Build NAT AMI" workflow (`nat_ami_build.yml`): triggers the
  `cabal-nat-al2023` Image Builder pipeline for the selected environment
  and waits for the image, so the instance-mode bootstrap and
  off-schedule rebuilds can be driven entirely from GitHub, without
  local AWS credentials.
