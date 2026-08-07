FROM binwiederhier/ntfy:v2.26.3@sha256:081b53dbb20674fcfe05fdb4eb8af9036a2645ef979543d16f7f80803af467b1

# The upstream image listens on 80 by default when NTFY_LISTEN_HTTP=:80.
# Cache + auth DB are expected at /var/cache/ntfy/ (EFS-backed in the
# task definition). Config is fully env-var driven (NTFY_*); no YAML
# file is needed.
#
# Token auth + deny-all default is applied via the task definition, not
# here, to keep the image environment-agnostic.

EXPOSE 80
