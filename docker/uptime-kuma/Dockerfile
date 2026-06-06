FROM louislam/uptime-kuma:1.23.13@sha256:96510915e6be539b76bcba2e6873591c67aca8a6075ff09f5b4723ae47f333fc

# The upstream image serves on 3001 with SQLite at /app/data.
# The ALB target group health check hits GET / which Kuma responds to
# with the dashboard HTML (200).

EXPOSE 3001
