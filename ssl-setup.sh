#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export NEWT_COLORS='
root=black,black
window=white,blue
title=white,blue
border=white,blue
textbox=white,blue
button=black,cyan
entry=black,cyan
label=white,blue
compactbutton=white,blue
listbox=black,cyan
actlistbox=black,cyan
actsellistbox=black,cyan
checkbox=white,blue
actcheckbox=black,cyan
'

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()     { echo -e "${CYAN}[•]${NC} $1"; }
success() { echo -e "${GREEN}[✔]${NC} $1"; }
warn()    { echo -e "${YELLOW}[⚠]${NC} $1"; }
err()     { echo -e "${RED}[✖]${NC} $1" >&2; }

cleanup() {
    local code=$?
    tput cnorm 2>/dev/null || true
    (( code != 0 )) && err "Script exited unexpectedly (code $code)."
}
trap cleanup EXIT

die() {
    whiptail --title "❌ Fatal Error" --msgbox "$1" 12 62
    exit 1
}

retry() {
    local attempts=$1 delay=$2
    shift 2
    local i=1
    until "$@"; do
        (( i >= attempts )) && return 1
        warn "Attempt $i/$attempts failed. Retrying in ${delay}s..."
        sleep "$delay"
        (( i++ ))
    done
}

if [[ $EUID -ne 0 ]]; then
    if sudo -n true 2>/dev/null; then
        SUDO="sudo"
    else
        echo -e "${RED}[✖]${NC} Run this script as root or with sudo."
        exit 1
    fi
else
    SUDO=""
fi

if ! command -v whiptail &>/dev/null; then
    log "Installing whiptail..."
    $SUDO apt-get install -y whiptail > /dev/null 2>&1 || \
    $SUDO dnf install -y newt > /dev/null 2>&1 || true
fi

whiptail --title "🔐 Nginx SSL Setup" --msgbox "\
╔══════════════════════════════════════╗
║     NGINX + LET'S ENCRYPT TOOL      ║
║     Automatic SSL Certificate        ║
║     Setup with Proxy Support         ║
╚══════════════════════════════════════╝

This tool will:
  • Install Nginx + Certbot
  • Verify DNS records
  • Obtain a free SSL certificate
  • Optionally configure a reverse proxy

Press OK to continue." 18 50

if [[ ! -f /etc/os-release ]]; then
    die "Cannot detect OS: /etc/os-release not found."
fi
source /etc/os-release

case "$ID" in
    ubuntu|debian|kali|pop|linuxmint)
        PACKAGES="nginx curl certbot python3-certbot-nginx dnsutils whiptail"
        UPDATE_CMD="$SUDO apt-get update -y"
        INSTALL_CMD="$SUDO apt-get install -y"
        ;;
    centos|rhel|fedora|almalinux|rocky)
        PACKAGES="nginx curl certbot python3-certbot-nginx bind-utils newt"
        UPDATE_CMD="$SUDO dnf check-update || true"
        INSTALL_CMD="$SUDO dnf install -y"
        ;;
    *)
        die "Unsupported OS: $ID"
        ;;
esac

{
    echo 10; echo "# Updating package repositories..."
    bash -c "$UPDATE_CMD" > /dev/null 2>&1 || true
    echo 40; echo "# Installing Nginx, Certbot, DNS utilities..."
    bash -c "$INSTALL_CMD $PACKAGES" > /dev/null 2>&1
    echo 80; echo "# Enabling and starting Nginx..."
    $SUDO systemctl enable nginx --now > /dev/null 2>&1
    echo 100; echo "# Done!"
} | whiptail --title "📦 Installing Dependencies" --gauge "Preparing..." 8 60 0

for cmd in nginx certbot; do
    if ! command -v "$cmd" &>/dev/null; then
        die "$cmd failed to install.\nCheck your internet connection and package sources."
    fi
done

success "Dependencies ready. Nginx is running."

while true; do
    RAW_DOMAIN=$(whiptail --title "🌐 Domain Setup" \
        --inputbox "\nEnter the domain to secure with SSL:\n\nExamples:\n  example.com\n  sub.example.com" \
        12 55 3>&1 1>&2 2>&3) || { log "Cancelled."; exit 0; }

    FULL_DOMAIN=$(echo "$RAW_DOMAIN" | sed -e 's|^[^/]*//||' -e 's|/.*$||' | tr -d ' ')
    [[ -n "$FULL_DOMAIN" ]] && break
    whiptail --title "⚠ Invalid Input" --msgbox "Domain cannot be empty. Please try again." 8 45
done

CERT_PATH="/etc/letsencrypt/live/$FULL_DOMAIN/fullchain.pem"
KEY_PATH="/etc/letsencrypt/live/$FULL_DOMAIN/privkey.pem"
SKIP_CERTBOT=0

if [[ -f "$CERT_PATH" && -f "$KEY_PATH" ]]; then
    EXPIRY=$(openssl x509 -enddate -noout -in "$CERT_PATH" 2>/dev/null | cut -d= -f2 || echo "Unknown")

    CHOICE=$(whiptail --title "🔐 Existing Certificate Found" \
        --menu "\nA certificate already exists for:\n  $FULL_DOMAIN\n\nExpires: $EXPIRY\n\nWhat would you like to do?" \
        16 60 3 \
        "USE"   "Use existing certificate (skip reissue)" \
        "RENEW" "Force renew certificate from scratch" \
        "ABORT" "Cancel and exit" \
        3>&1 1>&2 2>&3) || { log "Cancelled."; exit 0; }

    case "$CHOICE" in
        USE)   success "Using existing certificate for $FULL_DOMAIN."; SKIP_CERTBOT=1 ;;
        RENEW) log "Will force-renew the certificate."; SKIP_CERTBOT=0 ;;
        ABORT) log "Aborted by user."; exit 0 ;;
    esac
fi

log "Checking DNS for $FULL_DOMAIN..."

SERVER_IP=""
for svc in https://checkip.amazonaws.com https://api.ipify.org https://ifconfig.me; do
    SERVER_IP=$(curl -s --max-time 5 "$svc" | tr -d '[:space:]') && [[ -n "$SERVER_IP" ]] && break || true
done

DNS_IP=""
if command -v dig &>/dev/null; then
    DNS_IP=$(dig +short +timeout=10 +tries=3 "$FULL_DOMAIN" A | grep -E '^[0-9]+\.' | head -n1) || true
fi
[[ -z "$DNS_IP" ]] && command -v getent &>/dev/null && \
    DNS_IP=$(getent hosts "$FULL_DOMAIN" 2>/dev/null | awk '{print $1}' | head -n1) || true
[[ -z "$DNS_IP" ]] && command -v host &>/dev/null && \
    DNS_IP=$(host -t A "$FULL_DOMAIN" 2>/dev/null | awk '/has address/{print $NF}' | head -n1) || true

if [[ -n "$SERVER_IP" && -n "$DNS_IP" && "$SERVER_IP" != "$DNS_IP" ]]; then
    whiptail --title "⚠ DNS Mismatch" \
        --yesno "\nDomain:     $FULL_DOMAIN
Server IP:  $SERVER_IP
Domain IP:  $DNS_IP

The domain does NOT point to this server.
SSL issuance will likely FAIL.

Fix your DNS 'A' record first.

Proceed anyway (not recommended)?" \
        15 58 || { log "Aborted. Fix DNS and re-run."; exit 1; }
    warn "Proceeding despite DNS mismatch..."
elif [[ -n "$SERVER_IP" && "$SERVER_IP" == "$DNS_IP" ]]; then
    whiptail --title "✅ DNS Verified" \
        --msgbox "\nDNS is correct!\n\n  Domain:    $FULL_DOMAIN\n  Server IP: $SERVER_IP\n  Domain IP: $DNS_IP" \
        11 50
fi

[[ -f /etc/nginx/sites-enabled/default ]] && $SUDO rm -f /etc/nginx/sites-enabled/default

CONF_FILE="/etc/nginx/sites-available/$FULL_DOMAIN"

$SUDO tee "$CONF_FILE" >/dev/null <<NGINXEOF
server {
    listen 80;
    listen [::]:80;
    server_name $FULL_DOMAIN;

    location / {
        return 200 'SSL setup in progress...';
        add_header Content-Type text/plain;
    }
}
NGINXEOF

$SUDO ln -sf "$CONF_FILE" /etc/nginx/sites-enabled/

$SUDO nginx -t > /dev/null 2>&1 || die "Nginx config test failed. Check /etc/nginx/sites-available/$FULL_DOMAIN"
$SUDO systemctl reload nginx > /dev/null 2>&1

success "Nginx server block created for $FULL_DOMAIN"

if (( SKIP_CERTBOT == 0 )); then
    log "Requesting SSL certificate from Let's Encrypt..."
    CERTBOT_SUCCESS=0

    for attempt in 1 2 3; do
        if $SUDO certbot --nginx \
            -d "$FULL_DOMAIN" \
            --non-interactive \
            --agree-tos \
            --register-unsafely-without-email \
            --redirect 2>&1; then
            CERTBOT_SUCCESS=1
            break
        fi

        warn "Certbot attempt $attempt/3 failed."
        if (( attempt < 3 )); then
            whiptail --title "⚠ Certbot Failed (Attempt $attempt/3)" \
                --msgbox "\nCertbot failed on attempt $attempt of 3.\n\nCommon causes:\n  • Port 80 or 443 blocked by firewall\n  • DNS not yet propagated to Let's Encrypt\n  • Let's Encrypt rate limit hit\n\nWill retry in 15 seconds...\nCheck logs: /var/log/letsencrypt/letsencrypt.log" \
                15 58
            sleep 15
        fi
    done

    if (( CERTBOT_SUCCESS == 0 )); then
        die "Certbot failed after 3 attempts.\n\nTroubleshooting:\n  • sudo ufw allow 80 && sudo ufw allow 443\n  • Verify DNS: dig +short $FULL_DOMAIN A\n  • View logs: /var/log/letsencrypt/letsencrypt.log"
    fi

    success "SSL certificate obtained for $FULL_DOMAIN!"
fi

CERT_PATH="/etc/letsencrypt/live/$FULL_DOMAIN/fullchain.pem"
KEY_PATH="/etc/letsencrypt/live/$FULL_DOMAIN/privkey.pem"

[[ ! -f "$CERT_PATH" || ! -f "$KEY_PATH" ]] && \
    die "Certificate files missing after certbot.\n  $CERT_PATH\n  $KEY_PATH"

PROXY_PORT=""
if whiptail --title "🔁 Reverse Proxy" \
    --yesno "\nForward HTTPS traffic to a local application?\n\nExample: your app runs on port 3000 or 8080.\nNginx will route:\n  https://$FULL_DOMAIN → 127.0.0.1:PORT" \
    12 60; then

    while true; do
        PROXY_PORT=$(whiptail --title "🔁 Local App Port" \
            --inputbox "\nEnter the local port your application listens on:\n\nCommon ports: 3000, 5000, 8000, 8080" \
            10 52 3>&1 1>&2 2>&3) || break

        if [[ "$PROXY_PORT" =~ ^[0-9]+$ ]] && (( PROXY_PORT >= 1 && PROXY_PORT <= 65535 )); then
            break
        fi
        whiptail --title "⚠ Invalid Port" --msgbox "Enter a valid port number between 1 and 65535." 8 48
    done
fi

if [[ -n "$PROXY_PORT" ]]; then
    $SUDO tee "$CONF_FILE" >/dev/null <<NGINXEOF
server {
    listen 80;
    listen [::]:80;
    server_name $FULL_DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $FULL_DOMAIN;

    ssl_certificate $CERT_PATH;
    ssl_certificate_key $KEY_PATH;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_stapling on;
    ssl_stapling_verify on;

    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    location / {
        proxy_pass http://127.0.0.1:$PROXY_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_connect_timeout 60s;
        proxy_send_timeout    60s;
        proxy_read_timeout    60s;

        proxy_buffering on;
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
    }
}
NGINXEOF
    success "Proxy config written for port $PROXY_PORT."
else
    log "No proxy configured — keeping Certbot's default setup."
fi

$SUDO nginx -t > /dev/null 2>&1 || die "Final Nginx config test failed.\nCheck: $CONF_FILE\nRun: sudo nginx -t"
retry 3 5 $SUDO systemctl reload nginx || die "Failed to reload Nginx.\nCheck: journalctl -xe"
success "Nginx reloaded."

CRON_JOB="0 3 * * * /usr/bin/certbot renew --quiet --post-hook 'systemctl reload nginx'"
if ! ($SUDO crontab -l 2>/dev/null | grep -qF 'certbot renew'); then
    ( $SUDO crontab -l 2>/dev/null; echo "$CRON_JOB" ) | $SUDO crontab -
    success "Auto-renewal cron registered (runs daily at 3AM)."
fi

EXPIRY=$(openssl x509 -enddate -noout -in "$CERT_PATH" 2>/dev/null | cut -d= -f2 || echo "Unknown")
[[ -n "$PROXY_PORT" ]] && PROXY_LINE="Proxy:     https://$FULL_DOMAIN → 127.0.0.1:$PROXY_PORT" \
                       || PROXY_LINE="Proxy:     Not configured"

whiptail --title "🎉 Setup Complete!" --msgbox "\
╔══════════════════════════════════════╗
║         SSL SETUP SUCCESSFUL!        ║
╚══════════════════════════════════════╝

🔐 URL:       https://$FULL_DOMAIN
📂 Config:    /etc/nginx/sites-available/$FULL_DOMAIN
📜 Cert:      $CERT_PATH
📅 Expires:   $EXPIRY
🔁 $PROXY_LINE
🔄 Renewal:   Auto (daily at 3AM via cron)

Your site is now live and secured!" 18 62

echo ""
success "Done! Visit https://$FULL_DOMAIN"
echo ""
