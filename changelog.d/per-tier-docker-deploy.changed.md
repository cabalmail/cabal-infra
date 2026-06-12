- A push now rebuilds and rolls only the docker tiers whose build
  inputs changed, instead of every tier in scope. Each tier's filter
  covers `docker/<tier>/**`; the core mail tiers also rebuild on
  `docker/shared/**` and their own sendmail template. A change that
  does not touch imap no longer causes an imap service roll (and its
  client-facing gap), and single-tier changes stop paying for 3-12
  sibling builds. To make the divergence safe, Terraform now tracks
  image tags per tier: the plan job copies each `cabal-*` service's
  running tag into `/cabal/deployed_image_tag/<tier>` and each task
  definition reads its own tier's key, so a topology apply re-pins
  every tier to the image that tier is actually running. The legacy
  global key remains as the imap-tracking fallback for keys not yet
  written, and a CI check (`check-docker-tier-filters.sh`) fails the
  build if a Dockerfile's inputs drift from the filter map.
