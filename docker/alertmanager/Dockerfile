FROM prom/alertmanager:v0.32.2@sha256:b85533a2eb45865835315810315f6951331b2dbc8c93a6cf9a51e156a006a706

USER root

COPY alertmanager/alertmanager.yml.tmpl /etc/alertmanager/alertmanager.yml.tmpl
COPY alertmanager/entrypoint.sh /usr/local/bin/cabal-entrypoint.sh
RUN chmod +x /usr/local/bin/cabal-entrypoint.sh \
    && mkdir -p /etc/alertmanager-rendered \
    && chown -R nobody:nobody /etc/alertmanager-rendered

USER nobody

ENTRYPOINT ["/usr/local/bin/cabal-entrypoint.sh"]
