divert(-1)
include(`/usr/share/sendmail-cf/m4/cf.m4')
OSTYPE(`linux')dnl
define(`confLOG_LEVEL', `2')dnl
define(`confDEF_USER_ID',``8:12'')
define(`ALIAS_FILE',`/etc/aliases')dnl
define(`confPRIVACY_FLAGS', `authwarnings,needmailhelo,noexpn,novrfy')dnl
define(`confTO_QUEUERETURN', `4d')dnl
define(`confTO_QUEUEWARN', `4h')dnl
define(`confTO_ICONNECT', `15s')dnl
define(`confTO_CONNECT', `3m')dnl
define(`confTO_HELO', `2m')dnl
define(`confTO_MAIL', `1m')dnl
define(`confTO_RCPT', `1m')dnl
define(`confTO_DATAINIT', `1m')dnl
define(`confTO_DATABLOCK', `1m')dnl
define(`confTO_DATAFINAL', `1m')dnl
define(`confTO_RSET', `1m')dnl
define(`confTO_QUIT', `1m')dnl
define(`confTO_MISC', `1m')dnl
define(`confTO_COMMAND', `1m')dnl
define(`confTO_STARTTLS', `2m')dnl
undefine(`UUCP_RELAY')dnl
undefine(`BITNET_RELAY')dnl
define(`PROCMAIL_MAILER_PATH',`/usr/bin/procmail')dnl
define(`confAUTH_OPTIONS', `A y')dnl
TRUST_AUTH_MECH(`EXTERNAL DIGEST-MD5 CRAM-MD5 LOGIN PLAIN')dnl
define(`confAUTH_MECHANISMS', `EXTERNAL GSSAPI DIGEST-MD5 CRAM-MD5 LOGIN PLAIN')dnl
define(`confCACERT_PATH', `/etc/pki/tls/certs')dnl
define(`confCACERT', `/etc/pki/tls/certs/__CERT_DOMAIN__.ca-bundle')dnl
define(`confSERVER_CERT', `/etc/pki/tls/certs/__CERT_DOMAIN__.crt')dnl
define(`confSERVER_KEY', `/etc/pki/tls/private/__CERT_DOMAIN__.key')dnl
FEATURE(`always_add_domain')dnl
MASQUERADE_DOMAIN_FILE(`/etc/mail/masq-domains')dnl
FEATURE(`nouucp',`reject')dnl
FEATURE(`genericstable', `hash -o /etc/mail/genericstable')dnl
FEATURE(`mailertable', `hash -o /etc/mail/mailertable')dnl
FEATURE(`access_db', `hash -T<TMPF> /etc/mail/access')dnl
FEATURE(`greet_pause', 5000)dnl
FEATURE(`blacklist_recipients')dnl
FEATURE(`no_default_msa')dnl
DAEMON_OPTIONS(`Name=MTA')dnl
MAILER(procmail)dnl
MAILER(smtp)dnl
