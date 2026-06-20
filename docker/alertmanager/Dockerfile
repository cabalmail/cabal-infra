FROM prom/alertmanager:v0.33.0@sha256:af26fbe4dd1886ac0efd7bd55cd9027da262e105b137a376522b7c14c3626e4a

USER root

COPY alertmanager/alertmanager.yml.tmpl /etc/alertmanager/alertmanager.yml.tmpl
COPY alertmanager/entrypoint.sh /usr/local/bin/cabal-entrypoint.sh
RUN chmod +x /usr/local/bin/cabal-entrypoint.sh \
    && mkdir -p /etc/alertmanager-rendered \
    && chown -R nobody:nobody /etc/alertmanager-rendered

USER nobody

ENTRYPOINT ["/usr/local/bin/cabal-entrypoint.sh"]
