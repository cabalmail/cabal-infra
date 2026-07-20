# Self-hosted Healthchecks (Phase 2 monitoring & alerting).
# Upstream image runs Django + uWSGI on port 8000. SECRET_KEY, DB_NAME,
# ALLOWED_HOSTS, and SITE_ROOT are injected by the ECS task definition;
# SECRET_KEY arrives via the ECS `secrets` block from SSM Parameter Store.
FROM healthchecks/healthchecks:v4.3@sha256:cd7bcd94350818b3944f82eb5995f48bdeab8c8627977578a569ffa73f56f56f
EXPOSE 8000
