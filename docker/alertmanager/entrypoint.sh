#!/bin/sh
# Render runtime placeholders in alertmanager.yml and exec alertmanager.
#
# ALERT_SINK_URL: Lambda Function URL (from monitoring module output).
# ALERT_SECRET:   shared webhook secret pulled from SSM by ECS at task start.
#
# We sed-substitute the secret rather than using credentials_file because
# the rest of the entrypoint pattern in this repo writes secrets via env;
# keeping one mechanism is simpler than introducing a sidecar to write a
# file. The rendered config lives in /etc/alertmanager-rendered, which is
# tmpfs (or container-fs) — never written to EFS.
set -eu

: "${ALERT_SINK_URL:?ALERT_SINK_URL is required}"
: "${ALERT_SECRET:?ALERT_SECRET is required}"

CONFIG_OUT=/etc/alertmanager-rendered/alertmanager.yml

# Use a delimiter that won't appear in URLs or secrets.
sed \
  -e "s|__ALERT_SINK_URL__|${ALERT_SINK_URL}|g" \
  -e "s|__ALERT_SECRET__|${ALERT_SECRET}|g" \
  /etc/alertmanager/alertmanager.yml.tmpl > "$CONFIG_OUT"

# /alertmanager is the EFS-mounted state dir (silences, notification log).
exec /bin/alertmanager \
  --config.file="$CONFIG_OUT" \
  --storage.path=/alertmanager \
  --web.external-url="${ALERTMANAGER_EXTERNAL_URL:-http://localhost:9093}" \
  --web.listen-address=:9093
