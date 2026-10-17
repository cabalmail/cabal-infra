FROM binwiederhier/ntfy:v2.29.0@sha256:4c599cf0818965782f93f652bd843e92714992e84d6b88ad17713dc0951cda1f

# The upstream image listens on 80 by default when NTFY_LISTEN_HTTP=:80.
# Cache + auth DB are expected at /var/cache/ntfy/ (EFS-backed in the
# task definition). Config is fully env-var driven (NTFY_*); no YAML
# file is needed.
#
# Token auth + deny-all default is applied via the task definition, not
# here, to keep the image environment-agnostic.

EXPOSE 80
