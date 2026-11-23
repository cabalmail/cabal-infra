FROM binwiederhier/ntfy:v2.38.1@sha256:038da2be5e668fee6d36a62884eea48975e1b71c29a56964e5298c1b9165a573

# The upstream image listens on 80 by default when NTFY_LISTEN_HTTP=:80.
# Cache + auth DB are expected at /var/cache/ntfy/ (EFS-backed in the
# task definition). Config is fully env-var driven (NTFY_*); no YAML
# file is needed.
#
# Token auth + deny-all default is applied via the task definition, not
# here, to keep the image environment-agnostic.

EXPOSE 80
