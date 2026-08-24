FROM grafana/grafana:13.2.0@sha256:3fd54ae1214669f8355f065ec9f6445d5279a3d77095ab048ca045685272429b

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
