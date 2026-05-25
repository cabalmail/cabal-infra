# ───────────────────────────────────────────────────────────────
# Builder stage: compile Xapian + dovecot-fts-flatcurve from
# pinned upstream releases
# ───────────────────────────────────────────────────────────────
# AL2023 does not ship Xapian, so we build it from source and pair
# it with the fts_flatcurve plugin. Both stages share the same
# amazonlinux:2023 base, so the dovecot-devel headers in the
# builder match the dovecot runtime in the final image and the
# Xapian runtime libs we stage out link cleanly at load time.
#
# Pinned upstream:
#   https://xapian.org (Core 1.4.31)
#   https://github.com/slusarz/dovecot-fts-flatcurve (v1.0.5)
# Licences are preserved at /usr/share/doc/{xapian,fts-flatcurve}/
# in the runtime image; see docs/operations.md.
FROM amazonlinux:2023 AS fts-builder

ARG XAPIAN_VERSION=1.4.31
ARG FTS_FLATCURVE_VERSION=v1.0.5
ARG FTS_FLATCURVE_COMMIT=cdfdb18a44485ea9f0a67942ffdeac319a6bdbea

RUN dnf install -y \
      gcc gcc-c++ make autoconf automake libtool pkgconf-pkg-config \
      dovecot dovecot-devel \
      libicu libicu-devel zlib-devel \
      tar gzip xz ca-certificates \
    && dnf clean all

# ── Xapian core ────────────────────────────────────────────────
WORKDIR /build/xapian
ADD https://oligarchy.co.uk/xapian/${XAPIAN_VERSION}/xapian-core-${XAPIAN_VERSION}.tar.xz /build/xapian/xapian.tar.xz
RUN tar -xf xapian.tar.xz --strip-components=1 \
    && rm xapian.tar.xz \
    && ./configure --prefix=/usr --libdir=/usr/lib64 \
                   --disable-static --disable-documentation \
    && make -j"$(nproc)" \
    && make install \
    && make install-strip DESTDIR=/staging \
    && install -D -m 0644 COPYING /staging/usr/share/doc/xapian/COPYING \
    && install -D -m 0644 AUTHORS /staging/usr/share/doc/xapian/AUTHORS

# Trim build-only files out of the staged tree; the runtime image
# only needs the shared library plus the licence text.
RUN rm -rf /staging/usr/include \
           /staging/usr/share/man \
           /staging/usr/share/doc/xapian-core \
           /staging/usr/lib64/pkgconfig \
           /staging/usr/lib64/cmake \
    && find /staging/usr/lib64 -name '*.la' -delete \
    && rm -f /staging/usr/bin/xapian-config \
    && rm -rf /staging/usr/bin

# ── fts_flatcurve plugin ───────────────────────────────────────
WORKDIR /build/flatcurve
ADD https://github.com/slusarz/dovecot-fts-flatcurve/archive/${FTS_FLATCURVE_COMMIT}.tar.gz /build/flatcurve/src.tar.gz
RUN tar -xzf src.tar.gz --strip-components=1 \
    && rm src.tar.gz \
    && ./autogen.sh \
    && ./configure --with-dovecot=/usr/lib64/dovecot \
    && make -j"$(nproc)" \
    && make install-strip DESTDIR=/staging \
    && install -D -m 0644 COPYING /staging/usr/share/doc/fts-flatcurve/COPYING \
    && install -D -m 0644 AUTHORS /staging/usr/share/doc/fts-flatcurve/AUTHORS \
    && { \
         echo "dovecot-fts-flatcurve"; \
         echo "  version: ${FTS_FLATCURVE_VERSION}"; \
         echo "  commit:  ${FTS_FLATCURVE_COMMIT}"; \
         echo "  source:  https://github.com/slusarz/dovecot-fts-flatcurve"; \
         echo "  licence: LGPL-2.1 (see ./COPYING)"; \
         echo; \
         echo "xapian-core"; \
         echo "  version: ${XAPIAN_VERSION}"; \
         echo "  source:  https://xapian.org/"; \
         echo "  licence: GPL-2.0-or-later (see ../xapian/COPYING)"; \
       } > /staging/usr/share/doc/fts-flatcurve/THIRD-PARTY-LICENSES

# Prune dev-only artifacts dropped by the plugin install: the
# generated config header, the aclocal macro, and the libtool .a /
# .la archives that dovecot's runtime dlopen doesn't read.
RUN rm -rf /staging/usr/local \
           /staging/usr/share/aclocal \
    && find /staging/usr/lib64/dovecot \( -name '*.a' -o -name '*.la' \) -delete


# ───────────────────────────────────────────────────────────────
# Runtime image
# ───────────────────────────────────────────────────────────────
FROM amazonlinux:2023

# System packages
RUN dnf install -y \
      sendmail sendmail-cf \
      dovecot \
      fail2ban \
      procmail \
      rsyslog \
      httpd-tools \
      make \
      procps-ng \
      awscli-2 jq \
      pip \
      libicu \
    && pip install supervisor \
    && dnf clean all \
    && sed -i 's/^UID_MAX.*/UID_MAX                 2147483647/' /etc/login.defs \
    && sed -i 's/^GID_MAX.*/GID_MAX                 2147483647/' /etc/login.defs

# Xapian runtime library + fts_flatcurve plugin .so + licences,
# staged by the builder. The plugin loads at dovecot startup once
# 90-fts.conf adds it to mail_plugins.
COPY --from=fts-builder /staging/usr/lib64/        /usr/lib64/
COPY --from=fts-builder /staging/usr/share/doc/    /usr/share/doc/

# Static dovecot configuration
COPY imap/configs/dovecot/10-auth.conf       /etc/dovecot/conf.d/10-auth.conf
COPY imap/configs/dovecot/10-mail.conf       /etc/dovecot/conf.d/10-mail.conf
COPY imap/configs/dovecot/15-mailboxes.conf  /etc/dovecot/conf.d/15-mailboxes.conf
COPY imap/configs/dovecot/20-imap.conf       /etc/dovecot/conf.d/20-imap.conf
COPY imap/configs/dovecot/auth-master.conf   /etc/dovecot/conf.d/auth-master.conf.ext
COPY imap/configs/dovecot/10-logging.conf    /etc/dovecot/conf.d/10-logging.conf
COPY imap/configs/dovecot/90-fts.conf        /etc/dovecot/conf.d/90-fts.conf

# PAM for dovecot (Cognito auth)
COPY imap/configs/pam/dovecot               /etc/pam.d/dovecot

# Procmail
COPY imap/configs/procmailrc                /etc/procmailrc

# Static system aliases (dynamic aliases appended at startup)
COPY shared/aliases.static                 /etc/aliases.static

# Sendmail .mc template (placeholder for cert domain)
COPY templates/imap-sendmail.mc             /etc/mail/sendmail.mc.template

# Shared scripts
COPY shared/entrypoint.sh                  /entrypoint.sh
COPY shared/generate-config.sh             /usr/local/bin/generate-config.sh
COPY shared/sync-users.sh                  /usr/local/bin/sync-users.sh
COPY shared/reconfigure.sh                 /usr/local/bin/reconfigure.sh
COPY shared/sendmail-wrapper.sh            /usr/local/bin/sendmail-wrapper.sh

# Rsyslog config (ships sendmail logs to /var/log/maillog for CloudWatch)
COPY shared/rsyslog-mail.conf              /etc/rsyslog.conf

# Supervisord config
COPY imap/supervisord.conf                 /etc/supervisord.conf

RUN chmod +x /entrypoint.sh /usr/local/bin/*.sh \
    && ldconfig

EXPOSE 143 993 25

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD supervisorctl status | grep -v RUNNING && exit 1 || exit 0

ENTRYPOINT ["/entrypoint.sh"]
