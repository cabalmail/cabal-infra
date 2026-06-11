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
FROM prom/node-exporter:v1.11.1@sha256:e9cff4fc67b1818f8c97adb115b9f12c9a54b533de86765d4a0effc01b357205
