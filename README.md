# ip_monitor — Public IP Address Change Monitor

A lightweight Bash script for Ubuntu Server that detects changes to your server's public IP address, updates a config file to track old and current IPs, and sends an email notification when a change is detected.

---

## Files

| File | Description |
|---|---|
| `ip_monitor.sh` | Main monitoring script |
| `ip_monitor.conf` | Config file — stores IP addresses, email, and SMTP settings |
| `msmtprc.example` | Optional msmtp reference config for manual testing |
| `README.md` | This file |

---

## How It Works

1. Reads `CURRENT_IP` from `ip_monitor.conf`
2. Fetches the current public IP from a configurable web service (e.g. `api.ipify.org`)
3. **If the IP has changed:**
   - Copies `CURRENT_IP` → `OLD_IP` in the config file
   - Writes the new detected IP → `CURRENT_IP` in the config file
   - Sends an email notification via `msmtp`
4. **If the IP is unchanged:** logs the result and exits quietly
5. **On first run** (no `CURRENT_IP` stored): saves the detected IP and exits without sending email

The script builds a temporary msmtp config on the fly from the `SMTP_*` variables in `ip_monitor.conf`. **No separate `~/.msmtprc` file is needed.** The temporary config is deleted immediately after each send.

---

## Setup

### 1. Install msmtp

```bash
sudo apt update
sudo apt install msmtp msmtp-mta
```

### 2. Configure ip_monitor.conf

Edit `ip_monitor.conf` and fill in all your settings:

```bash
nano ip_monitor.conf
```

**Email settings to update:**

```bash
EMAIL_TO="you@example.com"              # Where to send notifications
EMAIL_FROM_NAME="IP Monitor"            # Display name in From: header
EMAIL_FROM="your-sender@example.com"    # Verified sender address in Brevo
EMAIL_SUBJECT="[IP Monitor] Public IP Address Changed"
```

**Brevo SMTP settings to update:**

```bash
SMTP_HOST="smtp-relay.brevo.com"
SMTP_PORT=587
SMTP_USER="your-brevo-account@example.com"   # Your Brevo login email
SMTP_PASSWORD="your-brevo-smtp-key"          # Brevo SMTP key (not your password)
SMTP_TLS="on"
SMTP_TLS_TRUST_FILE="/etc/ssl/certs/ca-certificates.crt"
```

> **Where to find your Brevo SMTP key:**  
> Log in to Brevo → **Settings** → **SMTP & API** → **SMTP** tab  
> The SMTP key is listed there. Your login username is your Brevo account email address.

> **Sender address:** The `EMAIL_FROM` address must be a verified sender in Brevo.  
> Verify it under **Senders & IP** → **Senders**.

### 3. Make the script executable

```bash
chmod +x ip_monitor.sh
```

### 4. Test the script manually

```bash
./ip_monitor.sh
```

On first run, it will detect and store your current IP without sending an email. To simulate a change, manually edit `CURRENT_IP` in `ip_monitor.conf` to a different value, then run the script again — it should update the config and send a notification email.

### 5. (Optional) Test msmtp independently

If you want to verify your SMTP credentials before running the script, use `msmtprc.example` as a reference:

```bash
cp msmtprc.example ~/.msmtprc
chmod 600 ~/.msmtprc
nano ~/.msmtprc   # fill in your Brevo credentials
echo "Subject: msmtp test" | msmtp your-email@example.com
```

### 6. Schedule with cron

Run the script automatically every 5 minutes:

```bash
crontab -e
```

Add this line (adjust paths as needed):

```
*/5 * * * * /path/to/ip_monitor.sh --config /path/to/ip_monitor.conf >> /var/log/ip_monitor_cron.log 2>&1
```

---

## Config File Reference

### IP Tracking (managed automatically)

| Variable | Description |
|---|---|
| `OLD_IP` | The previous IP address — set automatically when a change is detected |
| `CURRENT_IP` | The most recently confirmed IP address — set automatically |

### Email Settings

| Variable | Description |
|---|---|
| `EMAIL_TO` | Recipient email address for notifications |
| `EMAIL_FROM_NAME` | Display name shown in the From: header (e.g. `IP Monitor`) |
| `EMAIL_FROM` | Sender email address — must be a verified sender in Brevo |
| `EMAIL_SUBJECT` | Subject line for notification emails |

---

## Requirements

- Ubuntu Server (18.04+)
- `bash` 4.0+
- `curl` (usually pre-installed)
- `msmtp` and `msmtp-mta` (for email)
- `sed`, `stat`, `hostname` (standard GNU coreutils)
