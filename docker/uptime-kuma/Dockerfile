FROM louislam/uptime-kuma:2.5.8@sha256:20abea8c48a163cf0a7a5d5936ab418e4b742d908704e1f58f6c06e56a9c6b67

# The upstream image serves on 3001 with SQLite at /app/data.
# The ALB target group health check hits GET / which Kuma responds to
# with the dashboard HTML (200).

EXPOSE 3001
