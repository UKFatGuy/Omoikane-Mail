# Omoikane-Mail

A fully automated mail server setup for **omoikane.icu** (and any domain you choose), targeting **Ubuntu 24.04 LTS**.

The stack includes:

| Component | Role |
|-----------|------|
| **Postfix** | SMTP – send & receive email |
| **Dovecot** | IMAP / POP3 – client access |
| **OpenDKIM** | DKIM signing – deliverability |
| **Rspamd** | Spam / virus filtering |
| **Certbot** | Let's Encrypt TLS certificates |
| **Fail2ban** | Brute-force protection |
| **UFW** | Firewall |

---

## Quick Start

```bash
# Clone the repo onto your Ubuntu 24.04 server
git clone https://github.com/UKFatGuy/Omoikane-Mail.git
cd Omoikane-Mail

# Run the installer as root (or with sudo)
sudo bash install.sh
```

The script will prompt you for:
- Your **mail domain** (e.g. `omoikane.icu`)
- Your **mail hostname** (e.g. `mail.omoikane.icu`)
- A **postmaster / admin e-mail address**

> **Before running the script** make sure your DNS A record for `mail.omoikane.icu` points to this server's public IP address. The script uses Certbot to obtain a TLS certificate automatically, which requires that DNS resolution to already work.

---

## Full Guide

See **[SETUP_GUIDE.md](SETUP_GUIDE.md)** for a complete step-by-step walkthrough including:

1. Server pre-requisites & DNS records
2. What each installation step does
3. Post-install verification commands
4. How to add mail users
5. Connecting desktop / mobile clients
6. Troubleshooting tips

---

## Directory Layout

```
Omoikane-Mail/
├── install.sh          # Automated installer
├── SETUP_GUIDE.md      # Step-by-step manual guide
├── README.md           # This file
└── config/
    ├── postfix/
    │   ├── main.cf.template
    │   └── master.cf.template
    ├── dovecot/
    │   ├── dovecot.conf.template
    │   └── 10-ssl.conf.template
    ├── opendkim/
    │   └── opendkim.conf.template
    └── rspamd/
        └── worker-proxy.inc.template
```

---

## Licence

MIT – see [LICENSE](LICENSE) if present.
