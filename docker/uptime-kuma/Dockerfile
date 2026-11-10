FROM louislam/uptime-kuma:2.5.9@sha256:e88415a90dd2f7efecdbc18de0490aff292764a3ac471531bf1d0481725591bd

# The upstream image serves on 3001 with SQLite at /app/data.
# The ALB target group health check hits GET / which Kuma responds to
# with the dashboard HTML (200).

EXPOSE 3001
