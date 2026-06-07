FROM binwiederhier/ntfy:v2.14.0@sha256:5a051798d14138c3ecb12c038652558ab6a077e1aceeb867c151cbf5fa8451ef

# The upstream image listens on 80 by default when NTFY_LISTEN_HTTP=:80.
# Cache + auth DB are expected at /var/cache/ntfy/ (EFS-backed in the
# task definition). Config is fully env-var driven (NTFY_*); no YAML
# file is needed.
#
# Token auth + deny-all default is applied via the task definition, not
# here, to keep the image environment-agnostic.

EXPOSE 80
