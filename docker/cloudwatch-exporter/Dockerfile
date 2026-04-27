FROM prom/cloudwatch-exporter:v0.16.0

# Config is baked in. Updating metrics requires a rebuild + redeploy,
# which fits the existing CI flow (docker.yml builds the image, the
# downstream terraform.yml reads the new SHA tag from SSM and rolls
# the service).
COPY cloudwatch-exporter/config.yml /config/config.yml

CMD ["--config.file=/config/config.yml"]
