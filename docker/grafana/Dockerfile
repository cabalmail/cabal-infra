FROM grafana/grafana:13.1.0@sha256:121a7a9ece6dc10b969f1f96eed64b4f07dfac0d0b8abc070f7cb83bbde86f63

USER root

# File-based provisioning lets the container come up with the Prometheus
# data source and the Phase 3 dashboards already configured. Operator
# adjustments via the UI are still possible — Grafana persists them in
# its sqlite store on EFS, and provisioning won't overwrite UI changes
# on subsequent boots.
#
# Dashboards live under /etc/grafana/dashboards (not /var/lib/grafana)
# because /var/lib/grafana is the EFS mount path at runtime — anything
# baked there gets shadowed when the volume mounts.
COPY grafana/provisioning/ /etc/grafana/provisioning/
COPY grafana/dashboards/ /etc/grafana/dashboards/

# Grafana runs as uid 472:472 by default. The EFS access point is
# created with uid/gid 472 to match.
RUN chown -R 472:472 /etc/grafana/dashboards /etc/grafana/provisioning

USER grafana
