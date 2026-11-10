FROM binwiederhier/ntfy:v2.37.2@sha256:1875ddcf815c8a3c981d6d78c67a93452d0abba79b1ab9520b1f5f5238902bd7

# The upstream image listens on 80 by default when NTFY_LISTEN_HTTP=:80.
# Cache + auth DB are expected at /var/cache/ntfy/ (EFS-backed in the
# task definition). Config is fully env-var driven (NTFY_*); no YAML
# file is needed.
#
# Token auth + deny-all default is applied via the task definition, not
# here, to keep the image environment-agnostic.

EXPOSE 80
