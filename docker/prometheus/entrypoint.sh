#!/bin/sh
# Render runtime placeholders in prometheus.yml and exec prometheus.
#
# CONTROL_DOMAIN and ENVIRONMENT are injected via ECS task env vars.
# They have to be substituted at boot rather than baked into the image
# because the image is shared across prod/stage/dev environments.
set -eu

: "${CONTROL_DOMAIN:?CONTROL_DOMAIN is required}"
: "${ENVIRONMENT:?ENVIRONMENT is required}"

CONFIG_OUT=/etc/prometheus-rendered/prometheus.yml
mkdir -p "$(dirname "$CONFIG_OUT")"
sed \
  -e "s|__CONTROL_DOMAIN__|${CONTROL_DOMAIN}|g" \
  -e "s|__ENVIRONMENT__|${ENVIRONMENT}|g" \
  /etc/prometheus/prometheus.yml > "$CONFIG_OUT"

exec /bin/prometheus \
  --config.file="$CONFIG_OUT" \
  --storage.tsdb.path=/prometheus \
  --storage.tsdb.retention.time=30d \
  --web.console.libraries=/usr/share/prometheus/console_libraries \
  --web.console.templates=/usr/share/prometheus/consoles \
  --web.enable-lifecycle
