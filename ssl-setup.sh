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
    (( code != 0 )) && err "Script exited with code $code."
}
trap cleanup EXIT

die() {
    # Wrap long lines for whiptail display
    local msg
    msg=$(echo -e "$1" | fold -s -w 58)
    whiptail --title "❌ Fatal Error" --msgbox "$msg" 20 64
    exit 1
}

nginx_test_or_die() {
    local out
    if ! out=$($SUDO nginx -t 2>&1); then
        die "Nginx config test failed:\n\n$out\n\nFile: $CONF_FILE"
    fi
}

retry() {
    local attempts=$1 delay=$2
    shift 2
    local i=1
    until "$@"; do
        (( i >= attempts )) && return 1
        warn "Attempt $i/$attempts failed, retrying in ${delay}s..."
        sleep "$delay"
        (( i++ ))
    done
}

purge_old_nginx_config() {
    local domain="$1"
    log "Purging any existing Nginx config for $domain..."
    $SUDO rm -f "/etc/nginx/sites-enabled/$domain"
    $SUDO rm -f "/etc/nginx/sites-available/$domain"
    # Also remove any certbot-named variants
    $SUDO rm -f "/etc/nginx/sites-enabled/${domain}.conf"
    $SUDO rm -f "/etc/nginx/sites-available/${domain}.conf"
    # Remove default if present
    $SUDO rm -f /etc/nginx/sites-enabled/default
}

# ─── PRIVILEGE CHECK ──────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    if sudo -n true 2>/dev/null; then
        SUDO="sudo"
    else
        echo -e "${RED}[✖]${NC} Run as root or with sudo."
        exit 1
    fi
else
    SUDO=""
fi

# ─── WHIPTAIL BOOTSTRAP ───────────────────────────────────────────────────────
if ! command -v whiptail &>/dev/null; then
    log "Installing whiptail..."
    $SUDO apt-get install -y whiptail > /dev/null 2>&1 || \
    $SUDO dnf install -y newt > /dev/null 2>&1 || true
fi

# ─── WELCOME ──────────────────────────────────────────────────────────────────
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

# ─── OS DETECTION ─────────────────────────────────────────────────────────────
[[ ! -f /etc/os-release ]] && die "Cannot detect OS: /etc/os-release not found."
source /etc/os-release

case "$ID" in
    ubuntu|debian|kali|pop|linuxmint)
        PACKAGES="nginx curl certbot python3-certbot-nginx dnsutils whiptail openssl"
        UPDATE_CMD="$SUDO apt-get update -y"
        INSTALL_CMD="$SUDO apt-get install -y"
        ;;
    centos|rhel|fedora|almalinux|rocky)
        PACKAGES="nginx curl certbot python3-certbot-nginx bind-utils newt openssl"
        UPDATE_CMD="$SUDO dnf check-update || true"
        INSTALL_CMD="$SUDO dnf install -y"
        ;;
    *)
        die "Unsupported OS: $ID"
        ;;
esac

# ─── INSTALL DEPS ─────────────────────────────────────────────────────────────
{
    echo 10; echo "# Updating package repositories..."
    bash -c "$UPDATE_CMD" > /dev/null 2>&1 || true
    echo 40; echo "# Installing Nginx, Certbot, utilities..."
    bash -c "$INSTALL_CMD $PACKAGES" > /dev/null 2>&1
    echo 80; echo "# Starting Nginx..."
    $SUDO systemctl enable nginx --now > /dev/null 2>&1
    echo 100; echo "# Done!"
} | whiptail --title "📦 Installing Dependencies" --gauge "Preparing..." 8 60 0

for cmd in nginx certbot openssl; do
    command -v "$cmd" &>/dev/null || die "$cmd failed to install.\nCheck your internet connection."
done
success "Dependencies ready."

# ─── DOMAIN INPUT ─────────────────────────────────────────────────────────────
while true; do
    RAW_DOMAIN=$(whiptail --title "🌐 Domain Setup" \
        --inputbox "\nEnter the domain to secure with SSL:\n\nExamples:\n  example.com\n  sub.example.com" \
        12 55 3>&1 1>&2 2>&3) || { log "Cancelled."; exit 0; }

    FULL_DOMAIN=$(echo "$RAW_DOMAIN" | sed -e 's|^[^/]*//||' -e 's|/.*$||' | tr -d ' ')
    [[ -n "$FULL_DOMAIN" ]] && break
    whiptail --title "⚠ Invalid" --msgbox "Domain cannot be empty." 8 40
done

CONF_FILE="/etc/nginx/sites-available/$FULL_DOMAIN"
CERT_PATH="/etc/letsencrypt/live/$FULL_DOMAIN/fullchain.pem"
KEY_PATH="/etc/letsencrypt/live/$FULL_DOMAIN/privkey.pem"
SSL_OPTIONS="/etc/letsencrypt/options-ssl-nginx.conf"
SSL_DHPARAMS="/etc/letsencrypt/ssl-dhparams.pem"
SKIP_CERTBOT=0

# ─── EXISTING CERT CHECK ──────────────────────────────────────────────────────
if [[ -f "$CERT_PATH" && -f "$KEY_PATH" ]]; then
    EXPIRY=$(openssl x509 -enddate -noout -in "$CERT_PATH" 2>/dev/null | cut -d= -f2 || echo "Unknown")

    CHOICE=$(whiptail --title "🔐 Existing Certificate Found" \
        --menu "\nCertificate already exists for:\n  $FULL_DOMAIN\n\nExpires: $EXPIRY\n\nWhat would you like to do?" \
        16 60 3 \
        "USE"   "Use existing certificate (skip reissue)" \
        "RENEW" "Force renew certificate" \
        "ABORT" "Cancel and exit" \
        3>&1 1>&2 2>&3) || { log "Cancelled."; exit 0; }

    case "$CHOICE" in
        USE)   success "Using existing certificate."; SKIP_CERTBOT=1 ;;
        RENEW) log "Will force-renew."; SKIP_CERTBOT=0 ;;
        ABORT) exit 0 ;;
    esac
fi

# ─── DNS CHECK ────────────────────────────────────────────────────────────────
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

if [[ -n "$SERVER_IP" && -n "$DNS_IP" && "$SERVER_IP" != "$DNS_IP" ]]; then
    whiptail --title "⚠ DNS Mismatch" \
        --yesno "\nDomain:     $FULL_DOMAIN\nServer IP:  $SERVER_IP\nDomain IP:  $DNS_IP\n\nThis domain does NOT point here.\nSSL issuance will likely FAIL.\n\nProceed anyway?" \
        14 56 || { log "Aborted. Fix DNS and re-run."; exit 1; }
    warn "Proceeding despite DNS mismatch..."
elif [[ -n "$SERVER_IP" && "$SERVER_IP" == "$DNS_IP" ]]; then
    whiptail --title "✅ DNS OK" \
        --msgbox "\nDNS is correct!\n\n  Domain:    $FULL_DOMAIN\n  Server IP: $SERVER_IP" \
        10 50
fi

# ─── PURGE OLD CONFIG & START CLEAN ───────────────────────────────────────────
purge_old_nginx_config "$FULL_DOMAIN"

# Write minimal HTTP-only block so certbot can find server_name
# We do NOT use --redirect here — we handle redirects ourselves in the final config
$SUDO tee "$CONF_FILE" >/dev/null <<NGINXEOF
server {
    listen 80;
    listen [::]:80;
    server_name $FULL_DOMAIN;

    location / {
        return 200 'Setup in progress...';
        add_header Content-Type text/plain;
    }
}
NGINXEOF

$SUDO ln -sf "$CONF_FILE" /etc/nginx/sites-enabled/
nginx_test_or_die
$SUDO systemctl reload nginx > /dev/null 2>&1
success "Temporary Nginx block live for $FULL_DOMAIN"

# ─── OBTAIN CERTIFICATE (standalone mode — no nginx involvement) ───────────────
# We use certonly so certbot never touches our nginx config at all.
# We manage the nginx config 100% ourselves.
if (( SKIP_CERTBOT == 0 )); then
    log "Stopping Nginx briefly for certbot standalone mode..."
    $SUDO systemctl stop nginx > /dev/null 2>&1

    CERTBOT_SUCCESS=0
    for attempt in 1 2 3; do
        if $SUDO certbot certonly \
            --standalone \
            -d "$FULL_DOMAIN" \
            --non-interactive \
            --agree-tos \
            --register-unsafely-without-email \
            --preferred-challenges http 2>&1; then
            CERTBOT_SUCCESS=1
            break
        fi

        warn "Certbot attempt $attempt/3 failed."
        if (( attempt < 3 )); then
            whiptail --title "⚠ Certbot Failed ($attempt/3)" \
                --msgbox "\nAttempt $attempt of 3 failed.\n\nCommon causes:\n  • Port 80 blocked by firewall\n  • DNS not pointing here yet\n  • Let's Encrypt rate limit\n\nRetrying in 15 seconds...\nLog: /var/log/letsencrypt/letsencrypt.log" \
                15 60
            sleep 15
        fi
    done

    log "Starting Nginx again..."
    $SUDO systemctl start nginx > /dev/null 2>&1

    if (( CERTBOT_SUCCESS == 0 )); then
        die "Certbot failed after 3 attempts.\n\nTips:\n  sudo ufw allow 80\n  sudo ufw allow 443\n  dig +short $FULL_DOMAIN A\n  cat /var/log/letsencrypt/letsencrypt.log"
    fi

    success "SSL certificate obtained!"
fi

# ─── VERIFY CERT FILES ────────────────────────────────────────────────────────
[[ ! -f "$CERT_PATH" ]] && die "Certificate not found:\n$CERT_PATH"
[[ ! -f "$KEY_PATH"  ]] && die "Private key not found:\n$KEY_PATH"

# ─── ENSURE SSL SUPPORT FILES ─────────────────────────────────────────────────
if [[ ! -f "$SSL_OPTIONS" ]]; then
    warn "Downloading options-ssl-nginx.conf..."
    $SUDO curl -s "https://raw.githubusercontent.com/certbot/certbot/main/certbot-nginx/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf" \
        -o "$SSL_OPTIONS" || die "Failed to fetch options-ssl-nginx.conf"
fi

if [[ ! -f "$SSL_DHPARAMS" ]]; then
    warn "Generating DH params (takes ~30s)..."
    $SUDO openssl dhparam -out "$SSL_DHPARAMS" 2048 > /dev/null 2>&1 || \
        die "Failed to generate DH params."
fi

success "SSL support files ready."

# ─── PROXY SETUP ──────────────────────────────────────────────────────────────
PROXY_PORT=""
if whiptail --title "🔁 Reverse Proxy" \
    --yesno "\nForward HTTPS traffic to a local app?\n\nNginx will route:\n  https://$FULL_DOMAIN → 127.0.0.1:PORT\n\nUseful for Flask, Node, Django, etc." \
    12 58; then

    while true; do
        PROXY_PORT=$(whiptail --title "🔁 Local App Port" \
            --inputbox "\nPort your app listens on:\n\nExamples: 3000  5000  8000  8080" \
            10 50 3>&1 1>&2 2>&3) || break

        if [[ "$PROXY_PORT" =~ ^[0-9]+$ ]] && (( PROXY_PORT >= 1 && PROXY_PORT <= 65535 )); then
            break
        fi
        whiptail --title "⚠ Invalid Port" --msgbox "Enter a number between 1 and 65535." 8 44
    done
fi

# ─── WRITE FINAL CLEAN NGINX CONFIG ──────────────────────────────────────────
# Completely replace the file — no certbot modifications, no leftovers
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

    ssl_certificate      $CERT_PATH;
    ssl_certificate_key  $KEY_PATH;
    include              $SSL_OPTIONS;
    ssl_dhparam          $SSL_DHPARAMS;

    ssl_protocols             TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_session_cache         shared:SSL:10m;
    ssl_session_timeout       1d;
    ssl_stapling              on;
    ssl_stapling_verify       on;

    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    add_header X-Content-Type-Options   "nosniff"        always;
    add_header X-Frame-Options          "SAMEORIGIN"     always;
    add_header X-XSS-Protection         "1; mode=block"  always;
    add_header Referrer-Policy          "strict-origin-when-cross-origin" always;

    location / {
        proxy_pass         http://127.0.0.1:$PROXY_PORT;
        proxy_set_header   Host               \$host;
        proxy_set_header   X-Real-IP          \$remote_addr;
        proxy_set_header   X-Forwarded-For    \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto  \$scheme;

        proxy_http_version 1.1;
        proxy_set_header   Upgrade     \$http_upgrade;
        proxy_set_header   Connection  "upgrade";

        proxy_connect_timeout  60s;
        proxy_send_timeout     60s;
        proxy_read_timeout     60s;
        proxy_buffering        on;
        proxy_buffer_size      128k;
        proxy_buffers          4 256k;
    }
}
NGINXEOF
else
    # Static / no-proxy config
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

    ssl_certificate      $CERT_PATH;
    ssl_certificate_key  $KEY_PATH;
    include              $SSL_OPTIONS;
    ssl_dhparam          $SSL_DHPARAMS;

    ssl_protocols             TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_session_cache         shared:SSL:10m;
    ssl_session_timeout       1d;

    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    add_header X-Content-Type-Options "nosniff" always;

    root /var/www/html;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
NGINXEOF
fi

# ─── ENSURE SYMLINK ───────────────────────────────────────────────────────────
$SUDO ln -sf "$CONF_FILE" /etc/nginx/sites-enabled/

# ─── FINAL NGINX TEST & RELOAD ────────────────────────────────────────────────
nginx_test_or_die
retry 3 5 $SUDO systemctl reload nginx || die "Failed to reload Nginx.\nCheck: journalctl -xe"
success "Nginx reloaded successfully."

# ─── AUTO-RENEWAL CRON ────────────────────────────────────────────────────────
CRON_JOB="0 3 * * * /usr/bin/certbot renew --quiet --post-hook 'systemctl reload nginx'"
if ! ($SUDO crontab -l 2>/dev/null | grep -qF 'certbot renew'); then
    ( $SUDO crontab -l 2>/dev/null; echo "$CRON_JOB" ) | $SUDO crontab -
    success "Auto-renewal cron registered (daily at 3AM)."
fi

# ─── SUMMARY ──────────────────────────────────────────────────────────────────
EXPIRY=$(openssl x509 -enddate -noout -in "$CERT_PATH" 2>/dev/null | cut -d= -f2 || echo "Unknown")
[[ -n "$PROXY_PORT" ]] \
    && PROXY_LINE="🔁 Proxy:     → 127.0.0.1:$PROXY_PORT" \
    || PROXY_LINE="🔁 Proxy:     Not configured"

whiptail --title "🎉 Setup Complete!" --msgbox "\
╔══════════════════════════════════════╗
║         SSL SETUP SUCCESSFUL!        ║
╚══════════════════════════════════════╝

🔐 URL:       https://$FULL_DOMAIN
📂 Config:    $CONF_FILE
📜 Cert:      $CERT_PATH
📅 Expires:   $EXPIRY
$PROXY_LINE
🔄 Renewal:   Auto (daily at 3AM)

Your site is live and secured with HTTPS!" 19 62

echo ""
success "Done! → https://$FULL_DOMAIN"
echo ""
