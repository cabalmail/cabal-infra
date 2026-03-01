FROM amazonlinux:2023

# System packages
RUN dnf install -y \
      sendmail sendmail-cf \
      sendmail-milter \
      cyrus-sasl-plain \
      opendkim \
      fail2ban \
      procmail \
      rsyslog \
      make \
      awscli-2 jq \
      pip \
      stunnel \
    && pip install supervisor \
    && dnf clean all

# PAM for sendmail (Cognito auth)
COPY smtp-out/configs/pam/smtp             /etc/pam.d/smtp

# Cyrus SASL config — tells sendmail's SASL to use PAM directly
# (replaces saslauthd which ran on the old EC2/Chef instances)
COPY smtp-out/configs/sasl2/Sendmail.conf  /etc/sasl2/Sendmail.conf

# OpenDKIM static configuration
COPY smtp-out/configs/opendkim.conf        /etc/opendkim.conf

# Static sendmail access map
COPY smtp-out/configs/out-access           /etc/mail/access

# Sendmail .mc template (placeholder for cert domain)
COPY templates/out-sendmail.mc             /etc/mail/sendmail.mc.template

# stunnel config template for STARTTLS on port 587
COPY templates/stunnel-starttls.conf       /etc/stunnel/stunnel.conf.template

# Shared scripts
COPY shared/entrypoint.sh                  /entrypoint.sh
COPY shared/generate-config.sh             /usr/local/bin/generate-config.sh
COPY shared/sync-users.sh                  /usr/local/bin/sync-users.sh
COPY shared/reconfigure.sh                 /usr/local/bin/reconfigure.sh
COPY shared/sendmail-wrapper.sh            /usr/local/bin/sendmail-wrapper.sh

# Rsyslog config (ships sendmail logs to /var/log/maillog for CloudWatch)
COPY shared/rsyslog-mail.conf              /etc/rsyslog.conf

# Supervisord config
COPY smtp-out/supervisord.conf             /etc/supervisord.conf

RUN chmod +x /entrypoint.sh /usr/local/bin/*.sh

EXPOSE 25 587

ENTRYPOINT ["/entrypoint.sh"]
