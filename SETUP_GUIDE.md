# Omoikane-Mail – Complete Setup Guide

> **Target OS:** Ubuntu 24.04 LTS  
> **Domain:** `omoikane.icu`  
> **Mail hostname:** `mail.omoikane.icu`

This guide walks you through every step to build a production-ready mail server from scratch. If you prefer a fully automated path, run `sudo bash install.sh` instead and follow its prompts. This guide explains what is happening at every stage.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [DNS Records (do these first)](#2-dns-records-do-these-first)
3. [Server Preparation](#3-server-preparation)
4. [Install Packages](#4-install-packages)
5. [TLS Certificates with Let's Encrypt](#5-tls-certificates-with-lets-encrypt)
6. [Configure Postfix (SMTP)](#6-configure-postfix-smtp)
7. [Configure Dovecot (IMAP/POP3)](#7-configure-dovecot-imappop3)
8. [Configure OpenDKIM](#8-configure-opendkim)
9. [Configure Rspamd (Spam Filter)](#9-configure-rspamd-spam-filter)
10. [Configure Fail2ban (Brute-force Protection)](#10-configure-fail2ban-brute-force-protection)
11. [Configure UFW Firewall](#11-configure-ufw-firewall)
12. [Create Mail Users](#12-create-mail-users)
13. [Certificate Auto-Renewal](#13-certificate-auto-renewal)
14. [Verification & Testing](#14-verification--testing)
15. [Mail Client Configuration](#15-mail-client-configuration)
16. [Troubleshooting](#16-troubleshooting)

---

## 1. Prerequisites

### What you need before starting

| Item | Requirement |
|------|-------------|
| Server | Ubuntu 24.04 LTS VPS (at least 1 GB RAM) |
| Public IP | A static IPv4 address |
| Domain | `omoikane.icu` registered and pointing to your DNS provider |
| Port 25 | **Must not be blocked** by your VPS provider (many block it by default – open a ticket to unblock) |

### Check if port 25 is blocked

```bash
# From your local machine, test whether port 25 is reachable:
telnet mail.omoikane.icu 25
# OR
nc -zv mail.omoikane.icu 25
```

If it times out after DNS is configured, contact your VPS provider and ask them to unblock outbound SMTP (port 25).

---

## 2. DNS Records (do these first)

Log into your domain registrar / DNS panel for `omoikane.icu` and create the following records **before** running any commands on the server.

> Replace `203.0.113.10` with your actual server IP address.

### Required DNS records

| Type | Name | Value | Priority | TTL |
|------|------|-------|----------|-----|
| `A` | `mail` | `203.0.113.10` | – | 300 |
| `MX` | `@` | `mail.omoikane.icu` | `10` | 300 |
| `TXT` | `@` | `v=spf1 mx a:mail.omoikane.icu ~all` | – | 300 |
| `TXT` | `_dmarc` | `v=DMARC1; p=quarantine; rua=mailto:admin@omoikane.icu` | – | 300 |

### PTR (Reverse DNS) record

This one is set at your **VPS provider** control panel (not your domain registrar):

- IP: `203.0.113.10`  
- PTR value: `mail.omoikane.icu`

Many providers call this "Reverse DNS" or "rDNS". A missing PTR record causes your outbound mail to be rejected or marked as spam.

### Verify DNS propagation

```bash
# Check A record
dig +short A mail.omoikane.icu

# Check MX record
dig +short MX omoikane.icu

# Check SPF
dig +short TXT omoikane.icu

# Check PTR (replace with your real IP)
dig +short -x 203.0.113.10
```

---

## 3. Server Preparation

### SSH into your server

```bash
ssh root@mail.omoikane.icu
# or
ssh your-user@mail.omoikane.icu
sudo -i
```

### Update the system

```bash
apt-get update && apt-get upgrade -y
```

### Set the system hostname

```bash
hostnamectl set-hostname mail.omoikane.icu

# Verify
hostname -f
# Expected output: mail.omoikane.icu
```

### Add the hostname to /etc/hosts

```bash
# Edit /etc/hosts and make sure this line exists:
nano /etc/hosts
```

Add or update the line to read:

```
127.0.1.1   mail.omoikane.icu mail
```

---

## 4. Install Packages

```bash
# Pre-seed Postfix configuration so it does not open an interactive dialogue
echo "postfix postfix/mailname string mail.omoikane.icu" | debconf-set-selections
echo "postfix postfix/main_mailer_type string 'Internet Site'" | debconf-set-selections

apt-get install -y \
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
```

Verify Postfix is installed:

```bash
postconf mail_version
```

---

## 5. TLS Certificates with Let's Encrypt

Let's Encrypt provides free, auto-renewing TLS certificates. Certbot's `--standalone` mode temporarily starts an HTTP server on port 80 to prove you own the domain.

### Open port 80 temporarily

```bash
ufw allow 80/tcp
```

### Obtain the certificate

```bash
certbot certonly --standalone \
    --non-interactive \
    --agree-tos \
    --email admin@omoikane.icu \
    -d mail.omoikane.icu
```

This creates certificates at `/etc/letsencrypt/live/mail.omoikane.icu/`.

### Verify the certificate

```bash
ls -la /etc/letsencrypt/live/mail.omoikane.icu/
# You should see: cert.pem  chain.pem  fullchain.pem  privkey.pem

openssl x509 -in /etc/letsencrypt/live/mail.omoikane.icu/fullchain.pem -noout -dates
```

---

## 6. Configure Postfix (SMTP)

Postfix is the Mail Transfer Agent (MTA). It receives incoming email on port 25 and sends outgoing mail on ports 587 (STARTTLS) and 465 (SMTPS).

### Basic settings

```bash
postconf -e "myhostname = mail.omoikane.icu"
postconf -e "mydomain = omoikane.icu"
postconf -e "myorigin = \$mydomain"
postconf -e "inet_interfaces = all"
postconf -e "inet_protocols = ipv4"
postconf -e "mydestination = \$myhostname, localhost.\$mydomain, localhost, \$mydomain"
postconf -e "mynetworks = 127.0.0.0/8"
postconf -e "home_mailbox = Maildir/"
postconf -e "mailbox_size_limit = 0"
postconf -e "recipient_delimiter = +"
```

### TLS for incoming mail (smtpd)

```bash
postconf -e "smtpd_tls_cert_file = /etc/letsencrypt/live/mail.omoikane.icu/fullchain.pem"
postconf -e "smtpd_tls_key_file = /etc/letsencrypt/live/mail.omoikane.icu/privkey.pem"
postconf -e "smtpd_tls_security_level = may"
postconf -e "smtpd_tls_auth_only = yes"
postconf -e "smtpd_tls_protocols = !SSLv2,!SSLv3,!TLSv1,!TLSv1.1"
postconf -e "smtpd_tls_ciphers = high"
postconf -e "smtpd_tls_loglevel = 1"
```

### TLS for outgoing mail (smtp)

```bash
postconf -e "smtp_tls_security_level = may"
postconf -e "smtp_tls_protocols = !SSLv2,!SSLv3,!TLSv1,!TLSv1.1"
postconf -e "smtp_tls_ciphers = high"
postconf -e "smtp_tls_loglevel = 1"
```

### SASL authentication via Dovecot

```bash
postconf -e "smtpd_sasl_type = dovecot"
postconf -e "smtpd_sasl_path = private/auth"
postconf -e "smtpd_sasl_auth_enable = yes"
postconf -e "smtpd_recipient_restrictions = permit_sasl_authenticated,permit_mynetworks,reject_unauth_destination"
```

### Milter settings (for DKIM and Rspamd)

```bash
postconf -e "milter_default_action = accept"
postconf -e "milter_protocol = 6"
postconf -e "smtpd_milters = inet:localhost:8891,inet:localhost:11332"
postconf -e "non_smtpd_milters = inet:localhost:8891,inet:localhost:11332"
```

### Enable submission and SMTPS ports in master.cf

```bash
nano /etc/postfix/master.cf
```

Find the lines beginning with `#submission` and `#smtps` and uncomment them, or add the following block at the end of the file:

```
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
```

### Restart and verify Postfix

```bash
postfix check
systemctl restart postfix
systemctl status postfix

# Confirm all ports are listening
ss -tlnp | grep master
# Expected: 25, 465, 587
```

---

## 7. Configure Dovecot (IMAP/POP3)

Dovecot handles client access (Thunderbird, Outlook, mobile apps) and authenticates users for Postfix SASL.

### Write the main Dovecot configuration

```bash
cat > /etc/dovecot/dovecot.conf << 'EOF'
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
ssl_cert = </etc/letsencrypt/live/mail.omoikane.icu/fullchain.pem
ssl_key = </etc/letsencrypt/live/mail.omoikane.icu/privkey.pem
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
EOF
```

### Restart and verify Dovecot

```bash
dovecot -n        # Check for configuration errors
systemctl restart dovecot
systemctl status dovecot

ss -tlnp | grep dovecot
# Expected ports: 143 (IMAP), 993 (IMAPS), 110 (POP3), 995 (POP3S)
```

---

## 8. Configure OpenDKIM

DKIM (DomainKeys Identified Mail) cryptographically signs outgoing emails so receiving servers can verify they really came from your domain.

### Create the key directory and generate a key pair

```bash
mkdir -p /etc/opendkim/keys/omoikane.icu

# Generate a 2048-bit RSA key pair with selector name "mail"
opendkim-genkey -b 2048 -d omoikane.icu -D /etc/opendkim/keys/omoikane.icu -s mail -v

# Set correct ownership
chown -R opendkim:opendkim /etc/opendkim/keys
chmod 600 /etc/opendkim/keys/omoikane.icu/mail.private
```

### View the public key for DNS

```bash
cat /etc/opendkim/keys/omoikane.icu/mail.txt
```

You will see output similar to:

```
mail._domainkey IN TXT ( "v=DKIM1; h=sha256; k=rsa; "
    "p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA..." )
```

**Copy the entire `p=...` value** and create a DNS TXT record:

| Type | Name | Value |
|------|------|-------|
| `TXT` | `mail._domainkey` | `v=DKIM1; h=sha256; k=rsa; p=<your key>` |

### Write the OpenDKIM configuration

```bash
cat > /etc/opendkim.conf << 'EOF'
Syslog          yes
SyslogSuccess   yes
LogWhy          yes
Canonicalization  relaxed/simple
Domain          omoikane.icu
Selector        mail
KeyFile         /etc/opendkim/keys/omoikane.icu/mail.private
Socket          inet:8891@localhost
PidFile         /run/opendkim/opendkim.pid
OversignHeaders From
TrustAnchorFile /usr/share/dns/root.key
UserID          opendkim
UMask           007
EOF
```

### Create trust and key tables

```bash
cat > /etc/opendkim/TrustedHosts << 'EOF'
127.0.0.1
localhost
omoikane.icu
*.omoikane.icu
EOF

cat > /etc/opendkim/KeyTable << 'EOF'
mail._domainkey.omoikane.icu omoikane.icu:mail:/etc/opendkim/keys/omoikane.icu/mail.private
EOF

cat > /etc/opendkim/SigningTable << 'EOF'
*@omoikane.icu mail._domainkey.omoikane.icu
EOF
```

### Start OpenDKIM

```bash
systemctl enable --now opendkim
systemctl status opendkim

# Verify the socket is listening
ss -tlnp | grep 8891
```

### Verify DKIM signature after DNS propagates

```bash
# Send a test email and check headers, or use:
opendkim-testkey -d omoikane.icu -s mail -vvv
# Expected last line: key OK
```

---

## 9. Configure Rspamd (Spam Filter)

Rspamd scans incoming and outgoing messages and integrates with Postfix via milter on port 11332.

### Enable Redis (required by Rspamd)

```bash
systemctl enable --now redis-server
```

### Configure the milter worker

```bash
mkdir -p /etc/rspamd/local.d

cat > /etc/rspamd/local.d/worker-proxy.inc << 'EOF'
bind_socket = "localhost:11332";
milter = yes;
timeout = 120s;
upstream "local" {
  default = yes;
  self_scan = yes;
}
EOF

cat > /etc/rspamd/local.d/logging.inc << 'EOF'
level = "notice";
type = "syslog";
EOF
```

### Start Rspamd

```bash
systemctl enable --now rspamd
systemctl status rspamd

# Verify the milter port
ss -tlnp | grep 11332
```

### Access the Rspamd web UI (optional)

```bash
# Rspamd has a built-in web interface on port 11334 (localhost only by default)
# To access it temporarily through an SSH tunnel from your local machine:
# ssh -L 11334:localhost:11334 root@mail.omoikane.icu
# Then open http://localhost:11334 in your browser
```

---

## 10. Configure Fail2ban (Brute-force Protection)

Fail2ban monitors log files and blocks IP addresses that show malicious behaviour.

```bash
cat > /etc/fail2ban/jail.d/mail.conf << 'EOF'
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
EOF

systemctl enable --now fail2ban
systemctl status fail2ban

# Check active jails
fail2ban-client status
```

---

## 11. Configure UFW Firewall

```bash
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow 25/tcp    comment 'SMTP'
ufw allow 465/tcp   comment 'SMTPS'
ufw allow 587/tcp   comment 'Submission'
ufw allow 993/tcp   comment 'IMAPS'
ufw allow 995/tcp   comment 'POP3S'
ufw allow 80/tcp    comment 'HTTP (Certbot renewal)'
ufw --force enable

# Verify rules
ufw status verbose
```

---

## 12. Create Mail Users

Every mail user is a standard Linux system user. Their mail is stored in `~/Maildir/`.

### Add a new user

```bash
useradd -m -s /bin/bash alice
passwd alice

# Create Maildir skeleton
mkdir -p /home/alice/Maildir/{new,cur,tmp}
chown -R alice:alice /home/alice/Maildir
```

### Test sending mail to the new user

```bash
echo "Hello Alice" | mail -s "Test" alice@omoikane.icu

# Check the Maildir
ls /home/alice/Maildir/new/
```

### Add more users

Repeat the steps above for each additional user:

```bash
useradd -m -s /bin/bash bob
passwd bob
mkdir -p /home/bob/Maildir/{new,cur,tmp}
chown -R bob:bob /home/bob/Maildir
```

---

## 13. Certificate Auto-Renewal

Let's Encrypt certificates expire every 90 days. Add a cron job to renew them automatically and reload the mail services:

```bash
# Open the crontab for root
crontab -e
```

Add this line:

```
0 3 * * * certbot renew --quiet --post-hook 'systemctl reload postfix dovecot'
```

Test that renewal would work (dry-run, makes no changes):

```bash
certbot renew --dry-run
```

---

## 14. Verification & Testing

### Check all services are running

```bash
systemctl status postfix dovecot opendkim rspamd fail2ban
```

### Check all ports are listening

```bash
ss -tlnp | grep -E '25|465|587|993|995|143|110|8891|11332'
```

### Send a test email from the server

```bash
echo "Test body" | mail -s "Test Subject" you@gmail.com
```

Check the mail logs:

```bash
tail -f /var/log/mail.log
```

### Test SMTP with openssl

```bash
openssl s_client -connect mail.omoikane.icu:587 -starttls smtp
# Type: EHLO mail.omoikane.icu
# You should see 250-AUTH PLAIN LOGIN
```

### Test IMAP with openssl

```bash
openssl s_client -connect mail.omoikane.icu:993
# Type: . LOGIN username password
```

### Use an external mail tester

Send an email to one of these free testing services and review the score:

- **[mail-tester.com](https://www.mail-tester.com)** – Generates a unique address; email it and get a score out of 10
- **[mxtoolbox.com](https://mxtoolbox.com)** – Check MX, SPF, DKIM, DMARC, blacklists

### Verify DKIM DNS record

```bash
dig +short TXT mail._domainkey.omoikane.icu
```

### Verify SPF DNS record

```bash
dig +short TXT omoikane.icu | grep spf
```

---

## 15. Mail Client Configuration

Use these settings in Thunderbird, Outlook, Apple Mail, or any mobile app:

### Incoming Mail (IMAP – recommended)

| Setting | Value |
|---------|-------|
| Server | `mail.omoikane.icu` |
| Port | `993` |
| Connection security | `SSL/TLS` |
| Authentication | `Normal password` |
| Username | `alice` (just the local part, no @domain) |

### Outgoing Mail (SMTP)

| Setting | Value |
|---------|-------|
| Server | `mail.omoikane.icu` |
| Port | `587` |
| Connection security | `STARTTLS` |
| Authentication | `Normal password` |
| Username | `alice` |

### Incoming Mail (POP3 – alternative)

| Setting | Value |
|---------|-------|
| Server | `mail.omoikane.icu` |
| Port | `995` |
| Connection security | `SSL/TLS` |

---

## 16. Troubleshooting

### Mail log

```bash
tail -f /var/log/mail.log
tail -f /var/log/mail.err
```

### Postfix queue

```bash
# View queued messages
mailq

# Force delivery of queued mail
postqueue -f

# Delete all queued mail (careful!)
postsuper -d ALL
```

### Test Postfix configuration

```bash
postfix check
postconf -n      # Show non-default settings
```

### Test Dovecot configuration

```bash
dovecot -n
doveadm auth test alice
```

### Test OpenDKIM key

```bash
opendkim-testkey -d omoikane.icu -s mail -vvv
```

### Common issues

| Problem | Likely cause | Fix |
|---------|-------------|-----|
| Mail bounces with "relay access denied" | `mynetworks` or `smtpd_recipient_restrictions` | Verify SASL is working; check Postfix logs |
| Certificate errors | Certbot failed or cert path wrong | Re-run `certbot certonly ...`; check paths in `postconf -n` |
| DKIM fails | DNS TXT record not yet propagated or key mismatch | Wait up to 48 h; re-run `opendkim-testkey` |
| Mail goes to spam | Missing PTR record, low reputation | Add PTR, SPF, DMARC; test on mail-tester.com |
| Port 25 refused | VPS provider blocking it | Open a support ticket to unblock outbound port 25 |
| Fail2ban blocking you | Too many failed logins | `fail2ban-client set postfix unbanip YOUR_IP` |

### Check Fail2ban bans

```bash
fail2ban-client status postfix
fail2ban-client status dovecot
```

### Unban an IP address

```bash
fail2ban-client set postfix unbanip 203.0.113.1
```

---

## Summary of All DNS Records

| Type | Name | Value | Priority |
|------|------|-------|----------|
| `A` | `mail` | `<server IPv4>` | – |
| `MX` | `@` | `mail.omoikane.icu` | `10` |
| `TXT` | `@` | `v=spf1 mx a:mail.omoikane.icu ~all` | – |
| `TXT` | `mail._domainkey` | `v=DKIM1; h=sha256; k=rsa; p=<public key>` | – |
| `TXT` | `_dmarc` | `v=DMARC1; p=quarantine; rua=mailto:admin@omoikane.icu` | – |
| PTR | `<server IP>` | `mail.omoikane.icu` (set at VPS provider) | – |
