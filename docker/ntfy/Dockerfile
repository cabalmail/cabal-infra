FROM binwiederhier/ntfy:v2.26.0@sha256:a6d335064ae927c4dbef118e1fa39656b3d2e01472b2a82af5915d5cebfe815f

# The upstream image listens on 80 by default when NTFY_LISTEN_HTTP=:80.
# Cache + auth DB are expected at /var/cache/ntfy/ (EFS-backed in the
# task definition). Config is fully env-var driven (NTFY_*); no YAML
# file is needed.
#
# Token auth + deny-all default is applied via the task definition, not
# here, to keep the image environment-agnostic.

EXPOSE 80
