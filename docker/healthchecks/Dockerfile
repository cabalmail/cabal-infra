# Self-hosted Healthchecks (Phase 2 monitoring & alerting).
# Upstream image runs Django + uWSGI on port 8000. SECRET_KEY, DB_NAME,
# ALLOWED_HOSTS, and SITE_ROOT are injected by the ECS task definition;
# SECRET_KEY arrives via the ECS `secrets` block from SSM Parameter Store.
FROM healthchecks/healthchecks:v4.2@sha256:6b5f593d40994345053f05f86decfa9e17ab1e4422df2ae58abd032a7b14d8f6
EXPOSE 8000
