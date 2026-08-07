FROM grafana/grafana:13.1.1@sha256:7cb8c64c4d57a57e734073f3cc94620adb24a0acb929bd80ba9f14017e3a975b

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
