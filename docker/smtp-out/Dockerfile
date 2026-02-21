FROM amazonlinux:2023

# System packages
RUN dnf install -y \
      sendmail sendmail-cf \
      sendmail-milter \
      opendkim \
      fail2ban \
      procmail \
      make \
      awscli-2 jq \
      pip \
      net-tools \
    && pip install supervisor \
    && dnf clean all

# PAM for sendmail (Cognito auth)
COPY smtp-out/configs/pam/smtp             /etc/pam.d/smtp

# OpenDKIM static configuration
COPY smtp-out/configs/opendkim.conf        /etc/opendkim.conf

# Static sendmail access map
COPY smtp-out/configs/out-access           /etc/mail/access

# Sendmail .mc template (placeholder for cert domain)
COPY templates/out-sendmail.mc             /etc/mail/sendmail.mc.template

# Shared scripts
COPY shared/entrypoint.sh                  /entrypoint.sh
COPY shared/generate-config.sh             /usr/local/bin/generate-config.sh
COPY shared/sync-users.sh                  /usr/local/bin/sync-users.sh
COPY shared/reconfigure.sh                 /usr/local/bin/reconfigure.sh
COPY shared/sendmail-wrapper.sh            /usr/local/bin/sendmail-wrapper.sh

# Supervisord config
COPY smtp-out/supervisord.conf             /etc/supervisord.conf

RUN chmod +x /entrypoint.sh /usr/local/bin/*.sh

EXPOSE 25 465 587

ENTRYPOINT ["/entrypoint.sh"]
