FROM amazonlinux:2

# Enable EPEL (for fail2ban, supervisor) and install Python 3
RUN amazon-linux-extras install epel python3.8 -y

# System packages
RUN yum install -y \
      sendmail sendmail-cf \
      fail2ban \
      procmail \
      make \
      awscli jq \
      python3-pip \
      supervisor \
    && yum clean all

# Sendmail .mc template (placeholder for cert domain)
COPY templates/in-sendmail.mc               /etc/mail/sendmail.mc.template

# Shared scripts
COPY shared/entrypoint.sh                  /entrypoint.sh
COPY shared/generate-config.sh             /usr/local/bin/generate-config.sh
COPY shared/sync-users.sh                  /usr/local/bin/sync-users.sh
COPY shared/reconfigure.sh                 /usr/local/bin/reconfigure.sh

# Supervisord config
COPY smtp-in/supervisord.conf              /etc/supervisord.conf

RUN chmod +x /entrypoint.sh /usr/local/bin/*.sh

EXPOSE 25

ENTRYPOINT ["/entrypoint.sh"]
