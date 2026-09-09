# Self-hosted Healthchecks (Phase 2 monitoring & alerting).
# Upstream image runs Django + uWSGI on port 8000. SECRET_KEY, DB_NAME,
# ALLOWED_HOSTS, and SITE_ROOT are injected by the ECS task definition;
# SECRET_KEY arrives via the ECS `secrets` block from SSM Parameter Store.
FROM healthchecks/healthchecks:v4.4@sha256:aa08a61b0dcfd83f1332eab195d5cec1b595ae076eb8388cadf8a3d597114f9b
EXPOSE 8000
