FROM prom/alertmanager:v0.34.1@sha256:e9733bafb1bdef9b00e25a21f8f99dc26a22224bf16641ad754d1649f4c3357a

USER root

COPY alertmanager/alertmanager.yml.tmpl /etc/alertmanager/alertmanager.yml.tmpl
COPY alertmanager/entrypoint.sh /usr/local/bin/cabal-entrypoint.sh
RUN chmod +x /usr/local/bin/cabal-entrypoint.sh \
    && mkdir -p /etc/alertmanager-rendered \
    && chown -R nobody:nobody /etc/alertmanager-rendered

USER nobody

ENTRYPOINT ["/usr/local/bin/cabal-entrypoint.sh"]
