FROM amazonlinux:2023

# System packages
RUN dnf install -y \
      sendmail sendmail-cf \
      fail2ban \
      procmail \
      rsyslog \
      make \
      awscli-2 jq \
      pip \
      net-tools \
    && pip install supervisor \
    && dnf clean all

# Sendmail .mc template (placeholder for cert domain)
COPY templates/in-sendmail.mc               /etc/mail/sendmail.mc.template

# Shared scripts
COPY shared/entrypoint.sh                  /entrypoint.sh
COPY shared/generate-config.sh             /usr/local/bin/generate-config.sh
COPY shared/sync-users.sh                  /usr/local/bin/sync-users.sh
COPY shared/reconfigure.sh                 /usr/local/bin/reconfigure.sh
COPY shared/sendmail-wrapper.sh            /usr/local/bin/sendmail-wrapper.sh

# Rsyslog config (ships sendmail logs to /var/log/maillog for CloudWatch)
COPY shared/rsyslog-mail.conf              /etc/rsyslog.conf

# Supervisord config
COPY smtp-in/supervisord.conf              /etc/supervisord.conf

RUN chmod +x /entrypoint.sh /usr/local/bin/*.sh

EXPOSE 25

ENTRYPOINT ["/entrypoint.sh"]
