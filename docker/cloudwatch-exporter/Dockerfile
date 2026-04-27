FROM prom/cloudwatch-exporter:v0.16.0

# Config is baked in. Updating metrics requires a rebuild + redeploy,
# which fits the existing CI flow (docker.yml builds the image, the
# downstream terraform.yml reads the new SHA tag from SSM and rolls
# the service).
COPY cloudwatch-exporter/config.yml /config/config.yml

# The upstream entrypoint runs the cloudwatch_exporter Java jar; its
# main class takes a positional config path (NOT a Prometheus-style
# --config.file flag — that convention belongs to the Go-based Prom
# binaries). The previous CMD passed --config.file= which the JVM
# tried to parse as the port number and crashed at startup.
CMD ["/config/config.yml"]
