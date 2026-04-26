ARG UPTIME_KUMA_VERSION=1.23.13
FROM louislam/uptime-kuma:${UPTIME_KUMA_VERSION}

# The upstream image serves on 3001 with SQLite at /app/data.
# The ALB target group health check hits GET / which Kuma responds to
# with the dashboard HTML (200).

EXPOSE 3001
