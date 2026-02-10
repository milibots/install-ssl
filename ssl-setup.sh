#!/usr/bin/env bash
set -e

# =========================
# 🎨 COLORS & STYLES
# =========================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# =========================
# 🧾 LOG HELPERS
# =========================
info()    { echo -e "${BLUE}ℹ${NC}  $1"; }
success() { echo -e "${GREEN}✔${NC}  $1"; }
warn()    { echo -e "${YELLOW}⚠${NC}  $1"; }
error()   { echo -e "${RED}✖${NC}  $1"; }

separator() {
    echo -e "${CYAN}────────────────────────────────────────────${NC}"
}

# =========================
# 🎬 BANNER
# =========================
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

# =========================
# 🔐 PRIVILEGES
# =========================
if [[ $EUID -ne 0 ]]; then
    if sudo -n true 2>/dev/null; then
        SUDO="sudo"
    else
        error "Run this script with sudo"
        exit 1
    fi
else
    SUDO=""
fi

# =========================
# 🧠 OS DETECTION
# =========================
source /etc/os-release

case "$ID" in
    ubuntu|debian)
        PKG="apt"
        ;;
    centos|rhel|fedora)
        PKG="dnf"
        ;;
    *)
        error "Unsupported OS: $ID"
        exit 1
        ;;
esac

info "Detected OS: $PRETTY_NAME"

# =========================
# 📦 INSTALL DEPS
# =========================
separator
info "Installing dependencies..."

$SUDO $PKG update -y
$SUDO $PKG install -y nginx curl certbot python3-certbot-nginx dnsutils bind-utils || true

$SUDO systemctl enable nginx
$SUDO systemctl start nginx

success "Dependencies ready"

# =========================
# 🌍 USER INPUT
# =========================
separator
info "Domain configuration"

read -rp "Subdomain (use @ for root domain): " SUB
read -rp "Domain (example.com): " DOMAIN

if [[ -z "$DOMAIN" ]]; then
    error "Domain cannot be empty"
    exit 1
fi

if [[ "$SUB" == "@" ]]; then
    FULL_DOMAIN="$DOMAIN"
else
    FULL_DOMAIN="$SUB.$DOMAIN"
fi

success "Target domain: $FULL_DOMAIN"

# =========================
# 🌐 DNS CHECK
# =========================
separator
info "Checking DNS..."

SERVER_IP=$(curl -s https://checkip.amazonaws.com | tr -d ' ')
DNS_IP=$(dig +short "$FULL_DOMAIN" A | head -n1)

info "Server IP: $SERVER_IP"
info "DNS IP:    $DNS_IP"

if [[ "$SERVER_IP" != "$DNS_IP" ]]; then
    error "DNS does not point to this server"
    warn "Expected A record:"
    echo "  $FULL_DOMAIN → $SERVER_IP"
    exit 1
fi

success "DNS is correct"

# =========================
# 🌐 NGINX HTTP CONFIG
# =========================
separator
info "Configuring Nginx (HTTP)"

CONF="/etc/nginx/sites-available/$FULL_DOMAIN"

$SUDO tee "$CONF" >/dev/null <<EOF
server {
    listen 80;
    server_name $FULL_DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF

ln -sf "$CONF" /etc/nginx/sites-enabled/

nginx -t
$SUDO systemctl reload nginx

success "HTTP config applied"

# =========================
# 🔒 SSL CERT
# =========================
separator
info "Requesting SSL certificate..."

EMAIL="admin@$DOMAIN"

$SUDO certbot --nginx \
    -d "$FULL_DOMAIN" \
    --non-interactive \
    --agree-tos \
    -m "$EMAIL" \
    --redirect

success "SSL certificate issued"

# =========================
# 🔁 APP PROXY
# =========================
separator
read -rp "Forward to local app? (y/n): " PROXY

if [[ "$PROXY" =~ ^[Yy]$ ]]; then
    read -rp "App port: " PORT
    read -rp "App host [127.0.0.1]: " HOST
    HOST=${HOST:-127.0.0.1}

$SUDO tee "$CONF" >/dev/null <<EOF
server {
    listen 80;
    server_name $FULL_DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $FULL_DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$FULL_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$FULL_DOMAIN/privkey.pem;

    location / {
        proxy_pass http://$HOST:$PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

    nginx -t
    $SUDO systemctl reload nginx
    success "Proxy enabled → $HOST:$PORT"
else
    info "Skipping proxy setup"
fi

# =========================
# 🔄 AUTO RENEW
# =========================
separator
info "Testing auto-renewal..."
$SUDO certbot renew --dry-run && success "Auto-renew works"

# =========================
# 🎉 DONE
# =========================
separator
success "SSL setup completed!"
info "🔐 https://$FULL_DOMAIN"
info "📂 Certs: /etc/letsencrypt/live/$FULL_DOMAIN/"
info "🧾 Nginx: $CONF"
separator
