# Self-hosted Healthchecks (Phase 2 monitoring & alerting).
# Upstream image runs Django + uWSGI on port 8000. SECRET_KEY, DB_NAME,
# ALLOWED_HOSTS, and SITE_ROOT are injected by the ECS task definition;
# SECRET_KEY arrives via the ECS `secrets` block from SSM Parameter Store.
FROM healthchecks/healthchecks:v3.10@sha256:1b1dccd945c9cfe102947927065bbf26d100d9852830169c33de3ede82ee8e4b
EXPOSE 8000
