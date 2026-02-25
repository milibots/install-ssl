#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}ℹ${NC}  $1"; }
success() { echo -e "${GREEN}✔${NC}  $1"; }
warn()    { echo -e "${YELLOW}⚠${NC}  $1"; }
error()   { echo -e "${RED}✖${NC}  $1" >&2; }

separator() { echo -e "${CYAN}────────────────────────────────────────────${NC}"; }

retry() {
    local attempts=$1 delay=$2
    shift 2
    local i=1
    until "$@"; do
        if (( i >= attempts )); then
            error "Command failed after $attempts attempts: $*"
            return 1
        fi
        warn "Attempt $i/$attempts failed. Retrying in ${delay}s..."
        sleep "$delay"
        (( i++ ))
    done
}

cleanup() {
    local exit_code=$?
    if (( exit_code != 0 )); then
        error "Script exited with error (code $exit_code)."
    fi
}
trap cleanup EXIT

clear
echo -e "${BOLD}${CYAN}"
cat <<'EOF'
   ____  ____  _        ____       __
  / __ \/ __ \/ |      / / /______/ /_
 / / / / /_/ / | /| / / / __/ ___/ __/
/ /_/ / ____/| |/ |/ / / /_/ /__/ /_
\____/_/     |__/|__/_/\__/\___/\__/

        NGINX + LET'S ENCRYPT
      Automatic SSL Setup Tool
EOF
echo -e "${NC}"
separator

if [[ $EUID -ne 0 ]]; then
    if sudo -n true 2>/dev/null; then
        SUDO="sudo"
    else
        error "Please run this script as root or with sudo."
        exit 1
    fi
else
    SUDO=""
fi

if [[ ! -f /etc/os-release ]]; then
    error "Cannot detect OS: /etc/os-release not found."
    exit 1
fi

source /etc/os-release
info "Detected OS: $PRETTY_NAME"

PACKAGES=""
UPDATE_CMD=""
INSTALL_CMD=""

case "$ID" in
    ubuntu|debian|kali|pop|linuxmint)
        PACKAGES="nginx curl certbot python3-certbot-nginx dnsutils"
        UPDATE_CMD="$SUDO apt-get update -y"
        INSTALL_CMD="$SUDO apt-get install -y"
        ;;
    centos|rhel|fedora|almalinux|rocky)
        PACKAGES="nginx curl certbot python3-certbot-nginx bind-utils"
        UPDATE_CMD="$SUDO dnf check-update || true"
        INSTALL_CMD="$SUDO dnf install -y"
        ;;
    *)
        error "Unsupported OS: $ID"
        exit 1
        ;;
esac

separator
info "Updating package repositories..."
if ! retry 3 5 bash -c "$UPDATE_CMD" > /dev/null 2>&1; then
    warn "Repository update failed, proceeding with cached data..."
fi

info "Installing dependencies..."
if ! retry 3 10 bash -c "$INSTALL_CMD $PACKAGES"; then
    error "Failed to install required packages: $PACKAGES"
    exit 1
fi

for cmd in nginx certbot; do
    if ! command -v "$cmd" &>/dev/null; then
        error "$cmd is not available after installation."
        exit 1
    fi
done

if ! retry 3 5 $SUDO systemctl enable nginx --now > /dev/null 2>&1; then
    error "Failed to start Nginx."
    exit 1
fi

success "Dependencies installed & Nginx started."

separator
echo -e "Enter the domain you want to secure."
echo -e "Examples: ${YELLOW}example.com${NC} or ${YELLOW}sub.example.com${NC}"

while true; do
    read -rp "Domain: " RAW_DOMAIN
    FULL_DOMAIN=$(echo "$RAW_DOMAIN" | sed -e 's|^[^/]*//||' -e 's|/.*$||' | tr -d ' ')
    if [[ -n "$FULL_DOMAIN" ]]; then
        break
    fi
    error "Domain cannot be empty. Please try again."
done

success "Targeting: $FULL_DOMAIN"

separator
info "Verifying DNS records..."

SERVER_IP=""
for svc in https://checkip.amazonaws.com https://api.ipify.org https://ifconfig.me; do
    SERVER_IP=$(curl -s --max-time 5 "$svc" | tr -d '[:space:]') || true
    if [[ -n "$SERVER_IP" ]]; then
        break
    fi
done

if [[ -z "$SERVER_IP" ]]; then
    warn "Could not determine public IP. Skipping DNS check."
    DNS_SKIP=1
else
    DNS_SKIP=0
fi

if (( DNS_SKIP == 0 )); then
    DNS_IP=""
    if command -v dig &>/dev/null; then
        DNS_IP=$(dig +short +timeout=10 +tries=3 "$FULL_DOMAIN" A | grep -E '^[0-9]+\.' | head -n1) || true
    fi
    if [[ -z "$DNS_IP" ]] && command -v getent &>/dev/null; then
        DNS_IP=$(getent hosts "$FULL_DOMAIN" 2>/dev/null | awk '{print $1}' | head -n1) || true
    fi
    if [[ -z "$DNS_IP" ]] && command -v host &>/dev/null; then
        DNS_IP=$(host -t A "$FULL_DOMAIN" 2>/dev/null | awk '/has address/{print $NF}' | head -n1) || true
    fi

    info "Server IP : $SERVER_IP"
    info "Domain IP : ${DNS_IP:-Not Found}"

    if [[ "$SERVER_IP" != "$DNS_IP" ]]; then
        warn "DNS MISMATCH DETECTED!"
        echo -e "Domain ${BOLD}$FULL_DOMAIN${NC} does not point to this server (${SERVER_IP})."
        echo -e "Resolved IP: ${RED}${DNS_IP:-None}${NC}"
        echo -e "Update your DNS 'A' record before continuing."
        read -rp "Ignore and proceed anyway? (y/N): " FORCE
        if [[ ! "$FORCE" =~ ^[Yy]$ ]]; then
            info "Aborted. Fix DNS and re-run."
            exit 1
        fi
    else
        success "DNS is correct."
    fi
fi

if [[ -f /etc/nginx/sites-enabled/default ]]; then
    $SUDO rm -f /etc/nginx/sites-enabled/default
fi

separator
info "Requesting SSL certificate via Let's Encrypt..."

CERTBOT_SUCCESS=0
for attempt in 1 2 3; do
    if $SUDO certbot --nginx \
        -d "$FULL_DOMAIN" \
        --non-interactive \
        --agree-tos \
        --register-unsafely-without-email \
        --redirect; then
        CERTBOT_SUCCESS=1
        break
    else
        warn "Certbot attempt $attempt/3 failed."
        if (( attempt < 3 )); then
            info "Waiting 15 seconds before retry..."
            sleep 15
        fi
    fi
done

if (( CERTBOT_SUCCESS == 0 )); then
    error "Certbot failed after 3 attempts."
    error "Check: DNS propagation, firewall (ports 80/443 open), and domain ownership."
    exit 1
fi

success "SSL Certificate obtained successfully!"

separator
read -rp "Forward this domain to a local app/port? (y/n): " PROXY_ASK

if [[ "$PROXY_ASK" =~ ^[Yy]$ ]]; then
    while true; do
        read -rp "Local port (e.g. 3000, 8080): " PORT
        if [[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )); then
            break
        fi
        error "Invalid port. Enter a number between 1 and 65535."
    done

    CERT_PATH="/etc/letsencrypt/live/$FULL_DOMAIN/fullchain.pem"
    KEY_PATH="/etc/letsencrypt/live/$FULL_DOMAIN/privkey.pem"

    if [[ ! -f "$CERT_PATH" || ! -f "$KEY_PATH" ]]; then
        error "Certificate files not found at expected paths:"
        error "  $CERT_PATH"
        error "  $KEY_PATH"
        exit 1
    fi

    CONF_FILE="/etc/nginx/sites-available/$FULL_DOMAIN"

    $SUDO tee "$CONF_FILE" >/dev/null <<EOF
server {
    listen 80;
    server_name $FULL_DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $FULL_DOMAIN;

    ssl_certificate $CERT_PATH;
    ssl_certificate_key $KEY_PATH;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-XSS-Protection "1; mode=block" always;

    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;

        proxy_buffering on;
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
    }
}
EOF

    $SUDO ln -sf "$CONF_FILE" /etc/nginx/sites-enabled/

    if ! $SUDO nginx -t 2>&1; then
        error "Nginx config test failed. Check $CONF_FILE"
        exit 1
    fi

    if ! retry 3 5 $SUDO systemctl reload nginx; then
        error "Failed to reload Nginx."
        exit 1
    fi

    success "Proxy configured: https://$FULL_DOMAIN → 127.0.0.1:$PORT"
else
    info "Keeping default Certbot configuration."
fi

CRON_JOB="0 3 * * * /usr/bin/certbot renew --quiet --post-hook 'systemctl reload nginx'"
if ! ($SUDO crontab -l 2>/dev/null | grep -qF 'certbot renew'); then
    (($SUDO crontab -l 2>/dev/null; echo "$CRON_JOB") | $SUDO crontab -)
    success "Auto-renewal cron job added."
fi

separator
success "All done!"
echo -e "🔐 URL    : https://$FULL_DOMAIN"
echo -e "📂 Config : /etc/nginx/sites-available/$FULL_DOMAIN"
echo -e "🔄 Cert   : /etc/letsencrypt/live/$FULL_DOMAIN/"
separator
