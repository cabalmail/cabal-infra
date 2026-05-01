FROM prom/cloudwatch-exporter:v0.16.0

# Configs are baked in. Updating metrics requires a rebuild + redeploy,
# which fits the existing CI flow (app.yml builds the image, the ECS
# update-service step rolls the task with the new SHA tag).
#
# Two configs ship in the same image:
#   - config.yml: primary exporter, scrapes the infra's home region.
#   - config-us-east-1.yml: secondary exporter pinned to us-east-1
#     (AWS_REGION env on the task) for CloudFront, which is global-but-
#     only-emits-in-us-east-1.
# Each ECS task picks one via its CMD override; the primary keeps the
# default below.
COPY cloudwatch-exporter/config.yml /config/config.yml
COPY cloudwatch-exporter/config-us-east-1.yml /config/config-us-east-1.yml

# The upstream entrypoint runs the cloudwatch_exporter Java jar; its
# main class takes a positional config path (NOT a Prometheus-style
# --config.file flag — that convention belongs to the Go-based Prom
# binaries). The previous CMD passed --config.file= which the JVM
# tried to parse as the port number and crashed at startup.
CMD ["/config/config.yml"]
