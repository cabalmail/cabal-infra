FROM amazonlinux:2023@sha256:ad882807c6c88f478186fa2632637380e06071a303e2b3bd96ab71846a77c6a3

# System packages
RUN dnf install -y \
      sendmail sendmail-cf \
      procmail \
      rsyslog \
      make \
      procps-ng \
      awscli-2 jq \
      bind-utils \
      pip \
    && pip install supervisor \
    && dnf clean all \
    && sed -i 's/^UID_MAX.*/UID_MAX                 2147483647/' /etc/login.defs \
    && sed -i 's/^GID_MAX.*/GID_MAX                 2147483647/' /etc/login.defs

# Sendmail .mc template (placeholder for cert domain)
COPY templates/in-sendmail.mc               /etc/mail/sendmail.mc.template

# Sendmail service switch: consult /etc/hosts before DNS so the
# hosts-pin.sh IMAP pin is honored (see docker/shared/hosts-pin.sh).
COPY shared/service.switch                  /etc/mail/service.switch

# Shared scripts
COPY shared/entrypoint.sh                  /entrypoint.sh
COPY shared/generate-config.sh             /usr/local/bin/generate-config.sh
COPY shared/sync-users.sh                  /usr/local/bin/sync-users.sh
COPY shared/reconfigure.sh                 /usr/local/bin/reconfigure.sh
COPY shared/sendmail-wrapper.sh            /usr/local/bin/sendmail-wrapper.sh
COPY shared/prepare-sendmail.sh            /usr/local/bin/prepare-sendmail.sh
COPY shared/hosts-pin.sh                   /usr/local/bin/hosts-pin.sh

# Rsyslog config (ships sendmail logs to /var/log/maillog for CloudWatch)
COPY shared/rsyslog-mail.conf              /etc/rsyslog.conf

# Supervisord config
COPY smtp-in/supervisord.conf              /etc/supervisord.conf

RUN chmod +x /entrypoint.sh /usr/local/bin/*.sh

EXPOSE 25

ENTRYPOINT ["/entrypoint.sh"]
