FROM grafana/grafana:11.4.0

USER root

# File-based provisioning lets the container come up with the Prometheus
# data source and the Phase 3 dashboards already configured. Operator
# adjustments via the UI are still possible — Grafana persists them in
# its sqlite store on EFS, and provisioning won't overwrite UI changes
# on subsequent boots.
COPY grafana/provisioning/ /etc/grafana/provisioning/
COPY grafana/dashboards/ /var/lib/grafana/dashboards/

# Grafana runs as uid 472:472 by default. The EFS access point is
# created with uid/gid 472 to match.
RUN chown -R 472:472 /var/lib/grafana/dashboards /etc/grafana/provisioning

USER grafana
