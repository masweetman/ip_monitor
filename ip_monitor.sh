#!/usr/bin/env bash
# ============================================================
# ip_monitor.sh - Public IP Address Change Monitor
# ============================================================
# Detects changes in the server's public IP address, updates
# the config file, and sends an email notification on change.
#
# Usage:
#   ./ip_monitor.sh [--config /path/to/ip_monitor.conf]
#
# Recommended cron schedule (every 5 minutes):
#   */5 * * * * /path/to/ip_monitor.sh --config /path/to/ip_monitor.conf
# ============================================================

set -euo pipefail

# ------------------------------------------------------------
# Defaults
# ------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/ip_monitor.conf"

# ------------------------------------------------------------
# Parse arguments
# ------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config|-c)
            CONFIG_FILE="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [--config /path/to/ip_monitor.conf]"
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

# ------------------------------------------------------------
# Validate config file exists
# ------------------------------------------------------------
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Config file not found: $CONFIG_FILE" >&2
    exit 1
fi

# Source the config file to load variables
# shellcheck source=/dev/null
source "$CONFIG_FILE"

# ------------------------------------------------------------
# Logging
# ------------------------------------------------------------
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    local log_line="[$timestamp] [$level] $message"

    echo "$log_line"

    if [[ -n "${LOG_FILE:-}" ]]; then
        # Rotate log if it exceeds max size
        if [[ -f "$LOG_FILE" ]]; then
            local log_size
            log_size="$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)"
            if (( log_size > LOG_MAX_SIZE )); then
                mv "$LOG_FILE" "${LOG_FILE}.1"
                log INFO "Log rotated (exceeded ${LOG_MAX_SIZE} bytes)"
            fi
        fi
        echo "$log_line" >> "$LOG_FILE"
    fi
}

# ------------------------------------------------------------
# Validate required config values
# ------------------------------------------------------------
validate_config() {
    local errors=0

    if [[ -z "${EMAIL_TO:-}" || "$EMAIL_TO" == "your-email@example.com" ]]; then
        log ERROR "EMAIL_TO is not configured in $CONFIG_FILE"
        (( errors++ )) || true
    fi

    if [[ -z "${EMAIL_FROM:-}" || "$EMAIL_FROM" == "your-sender@example.com" ]]; then
        log ERROR "EMAIL_FROM is not configured in $CONFIG_FILE"
        (( errors++ )) || true
    fi

    if [[ -z "${IP_SERVICE:-}" ]]; then
        log ERROR "IP_SERVICE is not configured in $CONFIG_FILE"
        (( errors++ )) || true
    fi

    for var in SMTP_HOST SMTP_PORT SMTP_USER SMTP_PASSWORD SMTP_TLS SMTP_TLS_TRUST_FILE; do
        if [[ -z "${!var:-}" ]]; then
            log ERROR "SMTP config variable $var is not set in $CONFIG_FILE"
            (( errors++ )) || true
        fi
    done

    if (( errors > 0 )); then
        log ERROR "Please update $CONFIG_FILE before running this script."
        exit 1
    fi
}

# ------------------------------------------------------------
# Detect the current public IP address
# ------------------------------------------------------------
detect_public_ip() {
    local ip
    ip="$(curl --silent --max-time "${CURL_TIMEOUT:-10}" "$IP_SERVICE" 2>/dev/null | tr -d '[:space:]')"

    # Basic IPv4 validation
    if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        log ERROR "Failed to detect a valid public IP from $IP_SERVICE (got: '$ip')"
        return 1
    fi

    echo "$ip"
}

# ------------------------------------------------------------
# Update a variable's value in the config file
# Uses sed to replace the line: VAR_NAME="old_value"
# with:                         VAR_NAME="new_value"
# ------------------------------------------------------------
update_config_var() {
    local var_name="$1"
    local new_value="$2"

    # Escape forward slashes and ampersands in the value for use in sed
    local escaped_value
    escaped_value="$(printf '%s\n' "$new_value" | sed 's/[\/&]/\\&/g')"

    # Replace the variable assignment line in the config file
    sed -i "s|^${var_name}=.*|${var_name}=\"${escaped_value}\"|" "$CONFIG_FILE"
}

# ------------------------------------------------------------
# Send email notification via msmtp
#
# Builds a temporary msmtp config file from the SMTP_* variables
# in ip_monitor.conf — no separate ~/.msmtprc file is required.
# The temp file is always deleted after sending (it holds credentials).
# ------------------------------------------------------------
send_email() {
    local old_ip="$1"
    local new_ip="$2"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S %Z')"
    local host_name
    host_name="$(hostname -f 2>/dev/null || hostname)"

    # Check that msmtp is available
    if ! command -v msmtp &>/dev/null; then
        log ERROR "msmtp is not installed. Install it with: sudo apt install msmtp msmtp-mta"
        return 1
    fi

    # Write a temporary msmtp config (mode 600 — contains credentials)
    local tmp_msmtprc
    tmp_msmtprc="$(mktemp /tmp/msmtprc.XXXXXX)"
    chmod 600 "$tmp_msmtprc"

    # Build optional msmtp log line
    local msmtp_log_line=""
    if [[ -n "${MSMTP_LOG_FILE:-}" ]]; then
        msmtp_log_line="logfile        ${MSMTP_LOG_FILE}"
    fi

    # Write the msmtp config using values from ip_monitor.conf
    cat > "$tmp_msmtprc" <<MSMTPCONF
# Temporary msmtp config generated by ip_monitor.sh — do not edit
defaults
auth           on
tls            ${SMTP_TLS}
tls_trust_file ${SMTP_TLS_TRUST_FILE}
${msmtp_log_line}

account        ip_monitor
host           ${SMTP_HOST}
port           ${SMTP_PORT}
from           ${EMAIL_FROM}
user           ${SMTP_USER}
password       ${SMTP_PASSWORD}

account default : ip_monitor
MSMTPCONF

    # Build the RFC 2822 email message
    local from_header="${EMAIL_FROM_NAME:-IP Monitor} <${EMAIL_FROM}>"
    local email_body
    email_body="$(cat <<EMAILBODY
From: ${from_header}
To: ${EMAIL_TO}
Subject: ${EMAIL_SUBJECT}
Content-Type: text/plain; charset=UTF-8

Public IP Address Change Detected
==================================

Host:        ${host_name}
Detected at: ${timestamp}

Previous IP: ${old_ip}
New IP:      ${new_ip}

This is an automated notification from ip_monitor.sh.
EMAILBODY
)"

    # Send via msmtp using the temporary config, then always clean up
    local send_status=0
    if echo "$email_body" | msmtp --file="$tmp_msmtprc" --from="$EMAIL_FROM" "$EMAIL_TO"; then
        log INFO "Email notification sent to $EMAIL_TO"
    else
        log ERROR "Failed to send email notification via msmtp"
        send_status=1
    fi

    # Remove temp config — it contains SMTP credentials
    rm -f "$tmp_msmtprc"

    return $send_status
}

# ------------------------------------------------------------
# Main logic
# ------------------------------------------------------------
main() {
    log INFO "Starting IP monitor check"
    log INFO "Config file: $CONFIG_FILE"

    validate_config

    # Detect the current public IP
    local detected_ip
    if ! detected_ip="$(detect_public_ip)"; then
        log ERROR "Could not detect public IP address. Aborting."
        exit 1
    fi
    log INFO "Detected public IP: $detected_ip"

    # Load the stored current IP from config (may be empty on first run)
    local stored_ip="${CURRENT_IP:-}"

    # --- First run: no stored IP yet ---
    if [[ -z "$stored_ip" ]]; then
        log INFO "No stored IP found (first run). Saving detected IP as CURRENT_IP."
        update_config_var "CURRENT_IP" "$detected_ip"
        log INFO "CURRENT_IP set to $detected_ip. No notification sent."
        exit 0
    fi

    # --- IP has not changed ---
    if [[ "$detected_ip" == "$stored_ip" ]]; then
        log INFO "IP address unchanged: $stored_ip"
        exit 0
    fi

    # --- IP has changed ---
    log INFO "IP address change detected!"
    log INFO "  Old (stored CURRENT_IP): $stored_ip"
    log INFO "  New (detected):          $detected_ip"

    # 1. Move the old CURRENT_IP into OLD_IP
    log INFO "Updating OLD_IP to: $stored_ip"
    update_config_var "OLD_IP" "$stored_ip"

    # 2. Update CURRENT_IP to the newly detected IP
    log INFO "Updating CURRENT_IP to: $detected_ip"
    update_config_var "CURRENT_IP" "$detected_ip"

    # 3. Send email notification
    log INFO "Sending email notification..."
    if send_email "$stored_ip" "$detected_ip"; then
        log INFO "IP change handled successfully."
    else
        log ERROR "Email notification failed, but config file has been updated."
        exit 1
    fi
}

main "$@"
