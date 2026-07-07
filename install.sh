#!/usr/bin/env bash
# =============================================================================
# Omoikane-Mail – Automated Mail Server Installer for Ubuntu 24.04 LTS
# Stack: Postfix + Dovecot + OpenDKIM + Rspamd + Certbot + Fail2ban + UFW
# =============================================================================
set -euo pipefail

# --------------------------------------------------------------------------- #
# Colour helpers
# --------------------------------------------------------------------------- #
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[1;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# --------------------------------------------------------------------------- #
# Root check
# --------------------------------------------------------------------------- #
[[ $EUID -ne 0 ]] && die "Please run this script as root or with sudo."

# --------------------------------------------------------------------------- #
# OS check
# --------------------------------------------------------------------------- #
. /etc/os-release 2>/dev/null || die "Cannot read /etc/os-release"
[[ "$ID" == "ubuntu" && "$VERSION_ID" == "24.04" ]] \
    || warn "This script is tested on Ubuntu 24.04 LTS. Detected: $PRETTY_NAME"

# --------------------------------------------------------------------------- #
# Gather configuration from the user
# --------------------------------------------------------------------------- #
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}   Omoikane-Mail – Interactive Setup    ${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Mail domain (the part after @)
read -rp "Enter your mail domain (e.g. omoikane.icu): " MAIL_DOMAIN
MAIL_DOMAIN="${MAIL_DOMAIN:-omoikane.icu}"

# Fully qualified hostname of the mail server
read -rp "Enter the mail server hostname (e.g. mail.${MAIL_DOMAIN}): " MAIL_HOSTNAME
MAIL_HOSTNAME="${MAIL_HOSTNAME:-mail.${MAIL_DOMAIN}}"

# Postmaster address
read -rp "Enter the postmaster/admin email address (e.g. admin@${MAIL_DOMAIN}): " ADMIN_EMAIL
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@${MAIL_DOMAIN}}"

# First mail user
read -rp "Create a first mail user (username, no domain): " MAIL_USER
MAIL_USER="${MAIL_USER:-postmaster}"

echo ""
info "Configuration summary:"
echo "  Mail domain   : ${MAIL_DOMAIN}"
echo "  Mail hostname : ${MAIL_HOSTNAME}"
echo "  Admin email   : ${ADMIN_EMAIL}"
echo "  First user    : ${MAIL_USER}@${MAIL_DOMAIN}"
echo ""
read -rp "Proceed with this configuration? [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || die "Aborted by user."

# --------------------------------------------------------------------------- #
# Step 1 – System update
# --------------------------------------------------------------------------- #
info "Step 1/10 – Updating system packages …"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get upgrade -y -q
success "System updated."

# --------------------------------------------------------------------------- #
# Step 2 – Set hostname
# --------------------------------------------------------------------------- #
info "Step 2/10 – Configuring system hostname …"
hostnamectl set-hostname "${MAIL_HOSTNAME}"
# Ensure it appears in /etc/hosts
if ! grep -q "${MAIL_HOSTNAME}" /etc/hosts; then
    echo "127.0.1.1  ${MAIL_HOSTNAME} ${MAIL_HOSTNAME%%.*}" >> /etc/hosts
fi
success "Hostname set to ${MAIL_HOSTNAME}."

# --------------------------------------------------------------------------- #
# Step 3 – Install packages
# --------------------------------------------------------------------------- #
info "Step 3/10 – Installing mail server packages …"
# Pre-seed debconf so Postfix doesn't open its ncurses dialogue
echo "postfix postfix/mailname string ${MAIL_HOSTNAME}"   | debconf-set-selections
echo "postfix postfix/main_mailer_type string 'Internet Site'" | debconf-set-selections

apt-get install -y -q \
    postfix \
    postfix-pcre \
    dovecot-core \
    dovecot-imapd \
    dovecot-pop3d \
    dovecot-lmtpd \
    opendkim \
    opendkim-tools \
    certbot \
    fail2ban \
    ufw \
    rspamd \
    redis-server \
    mailutils \
    net-tools \
    curl \
    wget \
    openssl

success "Packages installed."

# --------------------------------------------------------------------------- #
# Step 4 – Obtain TLS certificate with Let's Encrypt
# --------------------------------------------------------------------------- #
info "Step 4/10 – Obtaining TLS certificate …"
info "  Temporarily opening port 80 for the ACME challenge …"
ufw allow 80/tcp 2>/dev/null || true

certbot certonly --standalone \
    --non-interactive \
    --agree-tos \
    --email "${ADMIN_EMAIL}" \
    -d "${MAIL_HOSTNAME}" \
    || die "Certbot failed. Ensure ${MAIL_HOSTNAME} resolves to this server's IP and port 80 is reachable."

CERT_DIR="/etc/letsencrypt/live/${MAIL_HOSTNAME}"
success "Certificate obtained. Stored in ${CERT_DIR}."

# --------------------------------------------------------------------------- #
# Step 5 – Configure Postfix
# --------------------------------------------------------------------------- #
info "Step 5/10 – Configuring Postfix …"

postconf -e "myhostname = ${MAIL_HOSTNAME}"
postconf -e "mydomain = ${MAIL_DOMAIN}"
postconf -e "myorigin = \$mydomain"
postconf -e "inet_interfaces = all"
postconf -e "inet_protocols = ipv4"
postconf -e "mydestination = \$myhostname, localhost.\$mydomain, localhost, \$mydomain"
postconf -e "mynetworks = 127.0.0.0/8"
postconf -e "home_mailbox = Maildir/"
postconf -e "mailbox_size_limit = 0"
postconf -e "recipient_delimiter = +"

# TLS for incoming (smtpd)
postconf -e "smtpd_tls_cert_file = ${CERT_DIR}/fullchain.pem"
postconf -e "smtpd_tls_key_file = ${CERT_DIR}/privkey.pem"
postconf -e "smtpd_tls_security_level = may"
postconf -e "smtpd_tls_auth_only = yes"
postconf -e "smtpd_tls_protocols = !SSLv2,!SSLv3,!TLSv1,!TLSv1.1"
postconf -e "smtpd_tls_ciphers = high"
postconf -e "smtpd_tls_loglevel = 1"

# TLS for outgoing (smtp)
postconf -e "smtp_tls_security_level = may"
postconf -e "smtp_tls_protocols = !SSLv2,!SSLv3,!TLSv1,!TLSv1.1"
postconf -e "smtp_tls_ciphers = high"
postconf -e "smtp_tls_loglevel = 1"

# Authentication / SASL (via Dovecot)
postconf -e "smtpd_sasl_type = dovecot"
postconf -e "smtpd_sasl_path = private/auth"
postconf -e "smtpd_sasl_auth_enable = yes"
postconf -e "smtpd_recipient_restrictions = permit_sasl_authenticated,permit_mynetworks,reject_unauth_destination"

# Milter protocol settings (sockets are set after step 8 once both
# OpenDKIM and Rspamd are configured)
postconf -e "milter_default_action = accept"
postconf -e "milter_protocol = 6"

# master.cf – enable submission (port 587) and smtps (port 465)
# Use postconf -M to avoid false negatives from commented-out lines
if ! postconf -M 2>/dev/null | grep -q "^submission/inet"; then
cat >> /etc/postfix/master.cf << 'MASTER_EOF'
submission inet n       -       y       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_tls_auth_only=yes
  -o smtpd_reject_unlisted_recipient=no
  -o smtpd_client_restrictions=$mua_client_restrictions
  -o smtpd_helo_restrictions=$mua_helo_restrictions
  -o smtpd_sender_restrictions=$mua_sender_restrictions
  -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
  -o milter_macro_daemon_name=ORIGINATING
smtps     inet  n       -       y       -       -       smtpd
  -o syslog_name=postfix/smtps
  -o smtpd_tls_wrappermode=yes
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_reject_unlisted_recipient=no
  -o smtpd_client_restrictions=$mua_client_restrictions
  -o smtpd_helo_restrictions=$mua_helo_restrictions
  -o smtpd_sender_restrictions=$mua_sender_restrictions
  -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
  -o milter_macro_daemon_name=ORIGINATING
MASTER_EOF
fi
success "Postfix configured."

# --------------------------------------------------------------------------- #
# Step 6 – Configure Dovecot
# --------------------------------------------------------------------------- #
info "Step 6/10 – Configuring Dovecot …"

# Main dovecot.conf
cat > /etc/dovecot/dovecot.conf << DOVECOT_EOF
protocols = imap pop3 lmtp
mail_location = maildir:~/Maildir
namespace inbox {
  inbox = yes
}
service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode = 0660
    user = postfix
    group = postfix
  }
}
auth_mechanisms = plain login
passdb {
  driver = pam
}
userdb {
  driver = passwd
}
ssl = required
ssl_cert = <${CERT_DIR}/fullchain.pem
ssl_key = <${CERT_DIR}/privkey.pem
ssl_min_protocol = TLSv1.2
ssl_cipher_list = ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384
ssl_prefer_server_ciphers = yes
service lmtp {
  unix_listener /var/spool/postfix/private/dovecot-lmtp {
    mode = 0600
    user = postfix
    group = postfix
  }
}
protocol imap {
  mail_max_userip_connections = 20
}
DOVECOT_EOF

success "Dovecot configured."

# --------------------------------------------------------------------------- #
# Step 7 – Configure OpenDKIM
# --------------------------------------------------------------------------- #
info "Step 7/10 – Configuring OpenDKIM …"

DKIM_DIR="/etc/opendkim/keys/${MAIL_DOMAIN}"
mkdir -p "${DKIM_DIR}"

# Generate keys (selector = mail)
opendkim-genkey -b 2048 -d "${MAIL_DOMAIN}" -D "${DKIM_DIR}" -s mail -v

chown -R opendkim:opendkim /etc/opendkim/keys
chmod 600 "${DKIM_DIR}/mail.private"

cat > /etc/opendkim.conf << DKIM_EOF
Syslog          yes
SyslogSuccess   yes
LogWhy          yes
Canonicalization  relaxed/simple
Domain          ${MAIL_DOMAIN}
Selector        mail
KeyFile         ${DKIM_DIR}/mail.private
Socket          inet:8891@localhost
PidFile         /run/opendkim/opendkim.pid
OversignHeaders From
TrustAnchorFile /usr/share/dns/root.key
UserID          opendkim
UMask           007
DKIM_EOF

# Create signing table and key table
cat > /etc/opendkim/TrustedHosts << TRUSTED_EOF
127.0.0.1
localhost
${MAIL_DOMAIN}
*.${MAIL_DOMAIN}
TRUSTED_EOF

cat > /etc/opendkim/KeyTable << KEYTABLE_EOF
mail._domainkey.${MAIL_DOMAIN} ${MAIL_DOMAIN}:mail:${DKIM_DIR}/mail.private
KEYTABLE_EOF

cat > /etc/opendkim/SigningTable << SIGNING_EOF
*@${MAIL_DOMAIN} mail._domainkey.${MAIL_DOMAIN}
SIGNING_EOF

success "OpenDKIM configured."
echo ""
echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}║  IMPORTANT – Add this DKIM TXT record to your DNS:              ║${NC}"
echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""
cat "${DKIM_DIR}/mail.txt"
echo ""
echo -e "${YELLOW}The record name is:  mail._domainkey.${MAIL_DOMAIN}${NC}"
echo -e "${YELLOW}Copy the p= value into a TXT record in your DNS panel.${NC}"
echo ""
read -rp "Press ENTER once you have noted down the DKIM record …" _

# --------------------------------------------------------------------------- #
# Step 8 – Configure Rspamd
# --------------------------------------------------------------------------- #
info "Step 8/10 – Configuring Rspamd …"

systemctl enable --now redis-server

cat > /etc/rspamd/local.d/worker-proxy.inc << RSPAMD_EOF
bind_socket = "localhost:11332";
milter = yes;
timeout = 120s;
upstream "local" {
  default = yes;
  self_scan = yes;
}
RSPAMD_EOF

cat > /etc/rspamd/local.d/logging.inc << RSPAMD_LOG_EOF
level = "notice";
type = "syslog";
RSPAMD_LOG_EOF

# DKIM signing via rspamd (optional – complements OpenDKIM)
# Disabled here to avoid double-signing; OpenDKIM handles it above.

# Set milter sockets now that both OpenDKIM (8891) and Rspamd (11332) are ready
postconf -e "smtpd_milters = inet:localhost:8891,inet:localhost:11332"
postconf -e "non_smtpd_milters = inet:localhost:8891,inet:localhost:11332"

success "Rspamd configured."

# --------------------------------------------------------------------------- #
# Step 9 – Configure Fail2ban
# --------------------------------------------------------------------------- #
info "Step 9/10 – Configuring Fail2ban …"

cat > /etc/fail2ban/jail.d/mail.conf << FAIL2BAN_EOF
[postfix]
enabled  = true
port     = smtp,submission,smtps
filter   = postfix
logpath  = /var/log/mail.log
maxretry = 5

[postfix-sasl]
enabled  = true
port     = smtp,submission,smtps
filter   = postfix[mode=auth]
logpath  = /var/log/mail.log
maxretry = 3

[dovecot]
enabled  = true
port     = pop3,pop3s,imap,imaps,submission,imapsubmission
filter   = dovecot
logpath  = /var/log/mail.log
maxretry = 5
FAIL2BAN_EOF

success "Fail2ban configured."

# --------------------------------------------------------------------------- #
# Step 10 – Configure UFW firewall
# --------------------------------------------------------------------------- #
info "Step 10/10 – Configuring UFW firewall …"

ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow 25/tcp    comment 'SMTP'
ufw allow 465/tcp   comment 'SMTPS'
ufw allow 587/tcp   comment 'Submission'
ufw allow 993/tcp   comment 'IMAPS'
ufw allow 995/tcp   comment 'POP3S'
ufw allow 80/tcp    comment 'HTTP (Let'\''s Encrypt renewal)'
ufw --force enable

success "Firewall configured."

# --------------------------------------------------------------------------- #
# Create first mail user
# --------------------------------------------------------------------------- #
info "Creating system mail user: ${MAIL_USER} …"
if id "${MAIL_USER}" &>/dev/null; then
    warn "User ${MAIL_USER} already exists, skipping creation."
else
    useradd -m -s /bin/bash "${MAIL_USER}"
    echo ""
    info "Set a password for ${MAIL_USER}:"
    passwd "${MAIL_USER}"
fi
# Create Maildir skeleton
mkdir -p "/home/${MAIL_USER}/Maildir/"{new,cur,tmp}
chown -R "${MAIL_USER}:${MAIL_USER}" "/home/${MAIL_USER}/Maildir"

# --------------------------------------------------------------------------- #
# Auto-renewal for Let's Encrypt
# --------------------------------------------------------------------------- #
info "Setting up automatic certificate renewal …"
if ! crontab -l 2>/dev/null | grep -q certbot; then
    (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet --post-hook 'systemctl reload postfix dovecot'") | crontab -
fi
success "Renewal cron job added."

# --------------------------------------------------------------------------- #
# Enable & restart all services
# --------------------------------------------------------------------------- #
info "Enabling and starting services …"
systemctl enable --now postfix dovecot opendkim rspamd fail2ban
systemctl restart  postfix dovecot opendkim rspamd fail2ban

success "All services started."

# --------------------------------------------------------------------------- #
# Final summary
# --------------------------------------------------------------------------- #
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║              Omoikane-Mail Installation Complete!               ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "  Mail domain   : ${MAIL_DOMAIN}"
echo "  Mail hostname : ${MAIL_HOSTNAME}"
echo "  Admin email   : ${ADMIN_EMAIL}"
echo "  First user    : ${MAIL_USER}@${MAIL_DOMAIN}"
echo ""
echo -e "${YELLOW}DNS records you MUST add to omoikane.icu:${NC}"
echo ""
echo "  Type  Name              Value"
echo "  ----  ----------------  -----------------------------------------"
echo "  A     mail              <this server's public IPv4>"
echo "  MX    @                 mail.${MAIL_DOMAIN}  (priority 10)"
echo "  TXT   @                 v=spf1 mx a:mail.${MAIL_DOMAIN} ~all"
echo "  TXT   mail._domainkey   (see the DKIM record printed above)"
echo "  TXT   _dmarc            v=DMARC1; p=quarantine; rua=mailto:${ADMIN_EMAIL}"
echo ""
echo -e "${YELLOW}Mail client settings:${NC}"
echo "  IMAP  host=${MAIL_HOSTNAME}  port=993  SSL=TLS   auth=password"
echo "  SMTP  host=${MAIL_HOSTNAME}  port=587  SSL=STARTTLS  auth=password"
echo ""
echo "See SETUP_GUIDE.md for full verification steps and troubleshooting."
echo ""
