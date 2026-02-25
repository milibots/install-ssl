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

log()     { echo -e "${CYAN}[•]${NC} $*"; }
success() { echo -e "${GREEN}[✔]${NC} $*"; }
warn()    { echo -e "${YELLOW}[⚠]${NC} $*"; }
err()     { echo -e "${RED}[✖]${NC} $*" >&2; }

# Always print errors to terminal AND try whiptail
die() {
    err "FATAL: $1"
    whiptail --title "❌ Fatal Error" --msgbox "$(echo -e "$1" | head -20)" 20 70 2>/dev/null || true
    exit 1
}

cleanup() {
    local code=$?
    tput cnorm 2>/dev/null || true
    if (( code != 0 )); then
        err "-------------------------------------------"
        err "Script failed with exit code $code"
        err "Run: sudo nginx -t    to see nginx errors"
        err "Run: journalctl -xe   to see system errors"
        err "-------------------------------------------"
    fi
}
trap cleanup EXIT

retry() {
    local attempts=$1 delay=$2; shift 2
    local i=1
    until "$@"; do
        (( i >= attempts )) && return 1
        warn "Attempt $i/$attempts failed, retrying in ${delay}s..."
        sleep "$delay"; (( i++ ))
    done
}

nginx_test_or_die() {
    local out
    out=$($SUDO nginx -t 2>&1) || {
        err "nginx -t output:"
        echo "$out" >&2
        die "Nginx config test FAILED.\n\nnginx -t output:\n$out\n\nFile: $CONF_FILE"
    }
    success "nginx -t passed."
}

# ─── PRIVILEGE CHECK ──────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    if sudo -n true 2>/dev/null; then SUDO="sudo"
    else err "Run as root or with sudo."; exit 1
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
║     Automatic SSL Setup + Proxy      ║
╚══════════════════════════════════════╝

This tool will:
  • Install Nginx + Certbot
  • Verify DNS records
  • Obtain a free SSL certificate
  • Optionally set up a reverse proxy

Press OK to continue." 17 50

# ─── OS DETECTION ─────────────────────────────────────────────────────────────
[[ ! -f /etc/os-release ]] && die "Cannot detect OS."
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
    *) die "Unsupported OS: $ID" ;;
esac

# ─── INSTALL DEPS ─────────────────────────────────────────────────────────────
{
    echo 10; echo "# Updating repositories..."
    bash -c "$UPDATE_CMD" > /dev/null 2>&1 || true
    echo 40; echo "# Installing packages..."
    bash -c "$INSTALL_CMD $PACKAGES" > /dev/null 2>&1
    echo 80; echo "# Starting Nginx..."
    $SUDO systemctl enable nginx --now > /dev/null 2>&1
    echo 100; echo "# Done!"
} | whiptail --title "📦 Installing Dependencies" --gauge "Preparing..." 8 60 0

for cmd in nginx certbot openssl; do
    command -v "$cmd" &>/dev/null || die "$cmd failed to install."
done
success "Dependencies ready. Nginx running."

# ─── DOMAIN INPUT ─────────────────────────────────────────────────────────────
while true; do
    RAW_DOMAIN=$(whiptail --title "🌐 Domain" \
        --inputbox "\nEnter the domain to secure:\n\nExamples:  example.com  /  sub.example.com" \
        11 55 3>&1 1>&2 2>&3) || { log "Cancelled."; exit 0; }
    FULL_DOMAIN=$(echo "$RAW_DOMAIN" | sed -e 's|^[^/]*//||' -e 's|/.*$||' | tr -d ' ')
    [[ -n "$FULL_DOMAIN" ]] && break
    whiptail --title "⚠" --msgbox "Domain cannot be empty." 8 36
done

log "Target domain: $FULL_DOMAIN"

CONF_FILE="/etc/nginx/sites-available/$FULL_DOMAIN"
CERT_PATH="/etc/letsencrypt/live/$FULL_DOMAIN/fullchain.pem"
KEY_PATH="/etc/letsencrypt/live/$FULL_DOMAIN/privkey.pem"
SSL_OPTIONS="/etc/letsencrypt/options-ssl-nginx.conf"
SSL_DHPARAMS="/etc/letsencrypt/ssl-dhparams.pem"
SKIP_CERTBOT=0
DO_RESET=0

# ─── EXISTING CONFIG / CERT DETECTION ────────────────────────────────────────
EXISTING_CONF=0
EXISTING_CERT=0
[[ -f "$CONF_FILE" || -f "/etc/nginx/sites-enabled/$FULL_DOMAIN" ]] && EXISTING_CONF=1
[[ -f "$CERT_PATH" && -f "$KEY_PATH" ]] && EXISTING_CERT=1

if (( EXISTING_CONF == 1 || EXISTING_CERT == 1 )); then
    STATUS_MSG=""
    (( EXISTING_CONF == 1 )) && STATUS_MSG+="  • Nginx config found: $CONF_FILE\n"
    if (( EXISTING_CERT == 1 )); then
        EXPIRY=$(openssl x509 -enddate -noout -in "$CERT_PATH" 2>/dev/null | cut -d= -f2 || echo "Unknown")
        STATUS_MSG+="  • SSL certificate found (expires: $EXPIRY)\n"
    fi

    CHOICE=$(whiptail --title "⚙ Existing Setup Detected" \
        --menu "\nFound existing setup for:\n  $FULL_DOMAIN\n\n$STATUS_MSG\nWhat do you want to do?" \
        20 65 4 \
        "RESET"  "🔄 Full reset — wipe config + cert, start fresh" \
        "RECONF" "⚙  Reconfigure — keep cert, rewrite nginx config" \
        "USE"    "✅ Use as-is — just update proxy/port settings" \
        "ABORT"  "✖  Cancel and exit" \
        3>&1 1>&2 2>&3) || { log "Cancelled."; exit 0; }

    case "$CHOICE" in
        RESET)
            whiptail --title "⚠ Confirm Full Reset" \
                --yesno "\nThis will:\n  • Delete nginx config for $FULL_DOMAIN\n  • Revoke and delete SSL certificate\n  • Start completely from scratch\n\nAre you sure?" \
                13 56 || { log "Reset cancelled."; exit 0; }
            DO_RESET=1
            SKIP_CERTBOT=0
            ;;
        RECONF)
            log "Reconfiguring nginx, keeping existing certificate."
            SKIP_CERTBOT=1
            DO_RESET=0
            ;;
        USE)
            log "Keeping existing cert and nginx, just updating settings."
            SKIP_CERTBOT=1
            DO_RESET=0
            ;;
        ABORT)
            exit 0
            ;;
    esac
fi

# ─── FULL RESET ───────────────────────────────────────────────────────────────
if (( DO_RESET == 1 )); then
    log "Performing full reset for $FULL_DOMAIN..."

    # Remove nginx configs
    $SUDO rm -f "/etc/nginx/sites-enabled/$FULL_DOMAIN"
    $SUDO rm -f "/etc/nginx/sites-available/$FULL_DOMAIN"
    $SUDO rm -f "/etc/nginx/sites-enabled/${FULL_DOMAIN}.conf"
    $SUDO rm -f "/etc/nginx/sites-available/${FULL_DOMAIN}.conf"

    # Revoke and delete certificate
    if [[ -f "$CERT_PATH" ]]; then
        log "Revoking certificate..."
        $SUDO certbot revoke --cert-path "$CERT_PATH" --non-interactive --agree-tos 2>&1 || \
            warn "Revoke failed (may already be expired), continuing..."
        $SUDO certbot delete --cert-name "$FULL_DOMAIN" --non-interactive 2>&1 || \
            warn "Delete failed, removing manually..."
        $SUDO rm -rf "/etc/letsencrypt/live/$FULL_DOMAIN"
        $SUDO rm -rf "/etc/letsencrypt/archive/$FULL_DOMAIN"
        $SUDO rm -f  "/etc/letsencrypt/renewal/$FULL_DOMAIN.conf"
    fi

    # Reload nginx to clear any active config
    $SUDO systemctl reload nginx > /dev/null 2>&1 || true
    success "Full reset complete."
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
        --yesno "\nServer IP:  $SERVER_IP\nDomain IP:  $DNS_IP\n\n$FULL_DOMAIN does NOT point here.\nSSL will likely FAIL.\n\nProceed anyway?" \
        13 54 || { log "Aborted — fix DNS first."; exit 1; }
    warn "Proceeding despite mismatch..."
elif [[ -n "$SERVER_IP" && "$SERVER_IP" == "$DNS_IP" ]]; then
    success "DNS OK — $FULL_DOMAIN → $SERVER_IP"
fi

# ─── CLEAN UP DEFAULT & OLD CONFIGS ──────────────────────────────────────────
$SUDO rm -f /etc/nginx/sites-enabled/default
$SUDO rm -f "/etc/nginx/sites-enabled/$FULL_DOMAIN"
$SUDO rm -f "/etc/nginx/sites-available/$FULL_DOMAIN"

# ─── CERTBOT — STANDALONE MODE (we control nginx entirely) ────────────────────
if (( SKIP_CERTBOT == 0 )); then
    log "Stopping Nginx for certbot standalone..."
    $SUDO systemctl stop nginx > /dev/null 2>&1

    CERTBOT_SUCCESS=0
    for attempt in 1 2 3; do
        log "Certbot attempt $attempt/3..."
        if $SUDO certbot certonly \
            --standalone \
            --preferred-challenges http \
            -d "$FULL_DOMAIN" \
            --non-interactive \
            --agree-tos \
            --register-unsafely-without-email 2>&1; then
            CERTBOT_SUCCESS=1
            break
        fi
        warn "Attempt $attempt failed."
        if (( attempt < 3 )); then
            whiptail --title "⚠ Certbot Failed ($attempt/3)" \
                --msgbox "\nAttempt $attempt of 3 failed.\n\nCommon causes:\n  • Port 80 blocked by firewall\n  • DNS not propagated yet\n  • Let's Encrypt rate limit\n\nRetrying in 15 seconds...\nLog: /var/log/letsencrypt/letsencrypt.log" \
                15 60
            sleep 15
        fi
    done

    log "Starting Nginx again..."
    $SUDO systemctl start nginx > /dev/null 2>&1

    if (( CERTBOT_SUCCESS == 0 )); then
        die "Certbot failed after 3 attempts.\n\nDebug:\n  sudo ufw allow 80\n  sudo ufw allow 443\n  dig +short $FULL_DOMAIN A\n  cat /var/log/letsencrypt/letsencrypt.log"
    fi
    success "Certificate obtained!"
fi

# ─── VERIFY CERT FILES ────────────────────────────────────────────────────────
[[ ! -f "$CERT_PATH" ]] && die "Certificate not found: $CERT_PATH"
[[ ! -f "$KEY_PATH"  ]] && die "Private key not found: $KEY_PATH"

# ─── SSL SUPPORT FILES ────────────────────────────────────────────────────────
if [[ ! -f "$SSL_OPTIONS" ]]; then
    warn "Downloading options-ssl-nginx.conf..."
    $SUDO curl -s "https://raw.githubusercontent.com/certbot/certbot/main/certbot-nginx/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf" \
        -o "$SSL_OPTIONS" || die "Failed to fetch options-ssl-nginx.conf"
fi
if [[ ! -f "$SSL_DHPARAMS" ]]; then
    warn "Generating DH params (~30s)..."
    $SUDO openssl dhparam -out "$SSL_DHPARAMS" 2048 > /dev/null 2>&1 || die "Failed to generate DH params."
fi
success "SSL support files ready."

# Verify the include files are actually valid paths nginx can read
[[ ! -f "$SSL_OPTIONS"  ]] && die "SSL options file missing: $SSL_OPTIONS"
[[ ! -f "$SSL_DHPARAMS" ]] && die "DH params file missing: $SSL_DHPARAMS"

# ─── PROXY PORT ───────────────────────────────────────────────────────────────
PROXY_PORT=""
if whiptail --title "🔁 Reverse Proxy" \
    --yesno "\nForward HTTPS traffic to a local app?\n\n  https://$FULL_DOMAIN → 127.0.0.1:PORT\n\nUseful for Flask, Node, Django, etc." \
    11 58; then
    while true; do
        PROXY_PORT=$(whiptail --title "🔁 Port" \
            --inputbox "\nLocal port your app listens on:\n\nExamples: 3000  5000  8000  8080" \
            10 48 3>&1 1>&2 2>&3) || break
        if [[ "$PROXY_PORT" =~ ^[0-9]+$ ]] && (( PROXY_PORT >= 1 && PROXY_PORT <= 65535 )); then
            break
        fi
        whiptail --title "⚠" --msgbox "Enter a valid port (1–65535)." 8 38
    done
fi

# ─── WRITE NGINX CONFIG ───────────────────────────────────────────────────────
log "Writing Nginx config to $CONF_FILE ..."

if [[ -n "$PROXY_PORT" ]]; then
    $SUDO bash -c "cat > '$CONF_FILE'" <<NGINXEOF
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
    add_header X-Content-Type-Options   "nosniff"       always;
    add_header X-Frame-Options          "SAMEORIGIN"    always;
    add_header X-XSS-Protection         "1; mode=block" always;
    add_header Referrer-Policy          "strict-origin-when-cross-origin" always;

    location / {
        proxy_pass         http://127.0.0.1:$PROXY_PORT;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;

        proxy_http_version 1.1;
        proxy_set_header   Upgrade    \$http_upgrade;
        proxy_set_header   Connection "upgrade";

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
    $SUDO bash -c "cat > '$CONF_FILE'" <<NGINXEOF
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
    index index.html index.htm;
    location / { try_files \$uri \$uri/ =404; }
}
NGINXEOF
fi

log "Config written. Contents:"
cat "$CONF_FILE"

# ─── ENABLE & TEST ────────────────────────────────────────────────────────────
$SUDO ln -sf "$CONF_FILE" /etc/nginx/sites-enabled/

log "Running nginx -t ..."
nginx_test_or_die

log "Reloading nginx..."
retry 3 5 $SUDO systemctl reload nginx || die "Nginx reload failed.\nRun: journalctl -xe"
success "Nginx reloaded."

# ─── AUTO-RENEWAL ─────────────────────────────────────────────────────────────
CRON_JOB="0 3 * * * /usr/bin/certbot renew --quiet --post-hook 'systemctl reload nginx'"
if ! ($SUDO crontab -l 2>/dev/null | grep -qF 'certbot renew'); then
    ( $SUDO crontab -l 2>/dev/null; echo "$CRON_JOB" ) | $SUDO crontab -
    success "Auto-renewal cron set (daily 3AM)."
fi

# ─── SUMMARY ──────────────────────────────────────────────────────────────────
EXPIRY=$(openssl x509 -enddate -noout -in "$CERT_PATH" 2>/dev/null | cut -d= -f2 || echo "Unknown")
[[ -n "$PROXY_PORT" ]] \
    && PROXY_LINE="🔁 Proxy:    → 127.0.0.1:$PROXY_PORT" \
    || PROXY_LINE="🔁 Proxy:    Not configured"

whiptail --title "🎉 Done!" --msgbox "\
╔══════════════════════════════════════╗
║         SSL SETUP SUCCESSFUL!        ║
╚══════════════════════════════════════╝

🔐 URL:      https://$FULL_DOMAIN
📂 Config:   $CONF_FILE
📅 Expires:  $EXPIRY
$PROXY_LINE
🔄 Renewal:  Auto (daily at 3AM)

Your site is live and secured!" 17 60

echo ""
success "All done! → https://$FULL_DOMAIN"
echo ""
