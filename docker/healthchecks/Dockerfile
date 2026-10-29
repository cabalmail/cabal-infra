# Self-hosted Healthchecks (Phase 2 monitoring & alerting).
# Upstream image runs Django + uWSGI on port 8000. SECRET_KEY, DB_NAME,
# ALLOWED_HOSTS, and SITE_ROOT are injected by the ECS task definition;
# SECRET_KEY arrives via the ECS `secrets` block from SSM Parameter Store.
FROM healthchecks/healthchecks:v5.0@sha256:ba6276c008de510930749f61646ba21f52413c211248297eb4896e4b0d1a8d2e
EXPOSE 8000
