# node_exporter runs as an ECS daemon-strategy service: one task per
# container instance. The task definition bind-mounts the host's /proc
# and /sys read-only and passes --path.rootfs=/host so node_exporter
# reports host-level CPU, memory, disk, and network — not the container
# view, which would be near-useless for fleet monitoring.
#
# We deviate slightly from the §3.2 plan, which framed node_exporter as
# a per-tier sidecar. A daemon service produces one set of host metrics
# per EC2, instead of three duplicates per host. See CHANGELOG for the
# rationale.
FROM prom/node-exporter:v1.9.1@sha256:d00a542e409ee618a4edc67da14dd48c5da66726bbd5537ab2af9c1dfc442c8a
