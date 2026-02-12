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
# 🔐 PRIVILEGES CHECK
# =========================
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

# =========================
# 🧠 OS DETECTION & PREP
# =========================
source /etc/os-release

info "Detected OS: $PRETTY_NAME"

PACKAGES=""
UPDATE_CMD=""
INSTALL_CMD=""

case "$ID" in
    ubuntu|debian|kali|pop|linuxmint)
        # Ubuntu uses dnsutils, not bind-utils
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

# =========================
# 📦 INSTALL DEPENDENCIES
# =========================
separator
info "Updating repositories..."
eval "$UPDATE_CMD" > /dev/null 2>&1

info "Installing dependencies (Nginx, Certbot, DNS Utils)..."
# We run this verbosely so you can see if errors happen
$INSTALL_CMD $PACKAGES

# Verify installation
if ! command -v nginx &> /dev/null; then
    error "Nginx failed to install."
    exit 1
fi

if ! command -v certbot &> /dev/null; then
    error "Certbot failed to install."
    exit 1
fi

# Enable Nginx
$SUDO systemctl enable nginx --now > /dev/null 2>&1

success "Dependencies installed & Nginx started"

# =========================
# 🌍 DOMAIN INPUT
# =========================
separator
echo -e "Enter the domain you want to secure."
echo -e "Examples: ${YELLOW}milud.ir${NC} or ${YELLOW}sub.milud.ir${NC}"
read -rp "Domain: " RAW_DOMAIN

# Clean input (remove http://, https://, trailing slashes, and whitespace)
FULL_DOMAIN=$(echo "$RAW_DOMAIN" | sed -e 's|^[^/]*//||' -e 's|/.*$||' | tr -d ' ')

if [[ -z "$FULL_DOMAIN" ]]; then
    error "Domain cannot be empty."
    exit 1
fi

success "Targeting: $FULL_DOMAIN"

# =========================
# 🌐 DNS CHECK
# =========================
separator
info "Verifying DNS records..."

# Get Public IP
SERVER_IP=$(curl -s https://checkip.amazonaws.com | tr -d ' ')

# Resolve Domain IP
if command -v dig &> /dev/null; then
    DNS_IP=$(dig +short "$FULL_DOMAIN" A | head -n1)
else
    # Fallback if dig fails specifically
    DNS_IP=$(getent hosts "$FULL_DOMAIN" | awk '{ print $1 }' | head -n1)
fi

info "Server IP: $SERVER_IP"
info "Domain IP: ${DNS_IP:-"Not Found"}"

if [[ "$SERVER_IP" != "$DNS_IP" ]]; then
    warn "DNS MISMATCH DETECTED!"
    echo -e "The domain ${BOLD}$FULL_DOMAIN${NC} does not point to this server ($SERVER_IP)."
    echo -e "Current IP points to: ${RED}$DNS_IP${NC}"
    echo -e "Please update your DNS 'A' record before continuing."
    
    read -rp "Ignore warning and proceed anyway? (y/N): " FORCE
    if [[ ! "$FORCE" =~ ^[Yy]$ ]]; then
        exit 1
    fi
else
    success "DNS is correct."
fi

# =========================
# ⚙️ CLEANUP OLD CONFIGS
# =========================
# Remove default config if it exists to prevent conflicts
if [[ -f /etc/nginx/sites-enabled/default ]]; then
    $SUDO rm -f /etc/nginx/sites-enabled/default
fi

# =========================
# 🔒 REQUEST SSL (CERTBOT)
# =========================
separator
info "Requesting SSL Certificate via Let's Encrypt..."

# We use Certbot to generate the initial config and cert
# This handles the temporary Nginx config automatically
$SUDO certbot --nginx \
    -d "$FULL_DOMAIN" \
    --non-interactive \
    --agree-tos \
    --register-unsafely-without-email \
    --redirect

if [[ $? -eq 0 ]]; then
    success "SSL Certificate obtained successfully!"
else
    error "Certbot failed. Check your DNS settings and Firewall (Ports 80/443)."
    exit 1
fi

# =========================
# 🔁 PROXY SETUP (OPTIONAL)
# =========================
separator
read -rp "Do you want to forward this domain to a local app/port? (y/n): " PROXY_ASK

if [[ "$PROXY_ASK" =~ ^[Yy]$ ]]; then
    read -rp "Enter Local Port (e.g., 3000, 8080): " PORT
    
    # Check if port is a number
    if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then
        error "Invalid port number."
        exit 1
    fi

    CONF_FILE="/etc/nginx/sites-available/$FULL_DOMAIN" # Certbot may have created this, or default

    # If certbot created a specific file name (usually domain.conf or default), we overwrite the HTTPS block
    # Note: Certbot usually modifies the file directly. We will rewrite it completely for stability.
    
    # Define Cert Paths
    CERT_PATH="/etc/letsencrypt/live/$FULL_DOMAIN/fullchain.pem"
    KEY_PATH="/etc/letsencrypt/live/$FULL_DOMAIN/privkey.pem"

$SUDO tee "$CONF_FILE" >/dev/null <<EOF
server {
    listen 80;
    server_name $FULL_DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl; # http2 is deprecated in newer nginx versions, removed for stability
    server_name $FULL_DOMAIN;

    ssl_certificate $CERT_PATH;
    ssl_certificate_key $KEY_PATH;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # WebSocket Support
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

    # Link it just in case
    $SUDO ln -sf "$CONF_FILE" /etc/nginx/sites-enabled/
    
    # Reload Nginx
    $SUDO nginx -t && $SUDO systemctl reload nginx
    success "Proxy setup complete: https://$FULL_DOMAIN → 127.0.0.1:$PORT"

else
    info "Keeping default Certbot static/redirect configuration."
fi

# =========================
# 🎉 FINAL SUMMARY
# =========================
separator
success "Installation Finished!"
echo -e "🔐 URL:   https://$FULL_DOMAIN"
echo -e "📂 Config: /etc/nginx/sites-available/$FULL_DOMAIN"
separator
