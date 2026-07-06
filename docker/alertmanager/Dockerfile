FROM prom/alertmanager:v0.33.1@sha256:9e082985f56f4c8c9f724e18f2288c6708f472e56a5286b8863d080434ea065d

USER root

COPY alertmanager/alertmanager.yml.tmpl /etc/alertmanager/alertmanager.yml.tmpl
COPY alertmanager/entrypoint.sh /usr/local/bin/cabal-entrypoint.sh
RUN chmod +x /usr/local/bin/cabal-entrypoint.sh \
    && mkdir -p /etc/alertmanager-rendered \
    && chown -R nobody:nobody /etc/alertmanager-rendered

USER nobody

ENTRYPOINT ["/usr/local/bin/cabal-entrypoint.sh"]
