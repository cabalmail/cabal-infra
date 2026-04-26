# Self-hosted Healthchecks (Phase 2 monitoring & alerting).
# Upstream image runs Django + uWSGI on port 8000. SECRET_KEY, DB_NAME,
# ALLOWED_HOSTS, and SITE_ROOT are injected by the ECS task definition;
# SECRET_KEY arrives via the ECS `secrets` block from SSM Parameter Store.
ARG HEALTHCHECKS_VERSION=v3.10
FROM healthchecks/healthchecks:${HEALTHCHECKS_VERSION}
EXPOSE 8000
