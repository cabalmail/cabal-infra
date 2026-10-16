FROM louislam/uptime-kuma:2.5.6@sha256:9912da7d7d9b6ddc0c2d904beb84d24689c1ed9c33b81419eb9008663a92a329

# The upstream image serves on 3001 with SQLite at /app/data.
# The ALB target group health check hits GET / which Kuma responds to
# with the dashboard HTML (200).

EXPOSE 3001
