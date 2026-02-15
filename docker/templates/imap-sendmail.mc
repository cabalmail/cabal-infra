divert(-1)dnl
include(`/usr/share/sendmail-cf/m4/cf.m4')dnl
VERSIONID(`setup for Red Hat Linux')dnl
OSTYPE(`linux')dnl
define(`confDEF_USER_ID',``8:12'')dnl
define(`confTO_CONNECT', `1m')dnl
define(`confTRY_NULL_MX_LIST',true)dnl
define(`confDONT_PROBE_INTERFACES',true)dnl
define(`PROCMAIL_MAILER_PATH',`/usr/bin/procmail')dnl
define(`ALIAS_FILE', `/etc/aliases')dnl
define(`UUCP_MAILER_MAX', `2000000')dnl
define(`confUSERDB_SPEC', `/etc/mail/userdb.db')dnl
define(`confPRIVACY_FLAGS', `authwarnings,novrfy,noexpn,restrictqrun')dnl
define(`confAUTH_OPTIONS', `A')dnl
define(`confBAD_RCPT_THROTTLE', `1')dnl
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
define(`confCACERT_PATH', `/etc/pki/tls/certs')dnl
define(`confCACERT', `/etc/pki/tls/certs/__CERT_DOMAIN__.ca-bundle')dnl
define(`confSERVER_CERT', `/etc/pki/tls/certs/__CERT_DOMAIN__.crt')dnl
define(`confSERVER_KEY', `/etc/pki/tls/private/__CERT_DOMAIN__.key')dnl
define(`confTO_IDENT', `0')dnl
FEATURE(`no_default_msa',`dnl')dnl
FEATURE(`smrsh',`/usr/sbin/smrsh')dnl
FEATURE(`mailertable',`hash -o /etc/mail/mailertable.db')dnl
FEATURE(`virtusertable',`hash -o /etc/mail/virtusertable.db')dnl
FEATURE(redirect)dnl
FEATURE(always_add_domain)dnl
FEATURE(use_cw_file)dnl
FEATURE(use_ct_file)dnl
FEATURE(local_procmail,`',`procmail -t -Y -a $h -d $u')dnl
FEATURE(`access_db',`hash -T<TMPF> -o /etc/mail/access.db')dnl
FEATURE(`blacklist_recipients')dnl
EXPOSED_USER(`root')dnl
LOCAL_DOMAIN(`localhost.localdomain')dnl
MAILER(smtp)dnl
MAILER(procmail)dnl
