#!/bin/bash

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# ASCII Art Banner
show_banner() {
    clear
    cat << "EOF"
    ╔══════════════════════════════════════════════════════════╗
    ║      ███████╗███████╗██╗         ███████╗███████╗██████╗ ║
    ║      ██╔════╝██╔════╝██║         ██╔════╝██╔════╝██╔══██╗║
    ║      ███████╗█████╗  ██║         ███████╗█████╗  ██████╔╝║
    ║      ╚════██║██╔══╝  ██║         ╚════██║██╔══╝  ██╔══██╗║
    ║      ███████║███████╗███████╗    ███████║███████╗██║  ██║║
    ║      ╚══════╝╚══════╝╚══════╝    ╚══════╝╚══════╝╚═╝  ╚═╝║
    ║                    Nginx SSL Setup Tool                   ║
    ╚══════════════════════════════════════════════════════════╝
EOF
    echo -e "${CYAN}Version 2.0 | Professional SSL Configuration Tool${NC}\n"
}

# Enhanced logging functions
log_info() {
    echo -e "${BLUE}ℹ  [INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}✓  [SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}⚠  [WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}✗  [ERROR]${NC} $1"
}

log_step() {
    echo -e "\n${MAGENTA}▶  [STEP]${NC} $1"
    echo "────────────────────────────────────────────────────────────"
}

# Check if script has root privileges
check_privileges() {
    if [[ $EUID -eq 0 ]]; then
        SUDO=""
        log_info "Running with root privileges"
    else
        if sudo -n true 2>/dev/null; then
            SUDO="sudo"
            log_info "Using sudo for privileged commands"
        else
            log_error "This script requires root privileges for SSL setup"
            echo -e "\n${YELLOW}Please run with:${NC}"
            echo "  sudo bash $0"
            exit 1
        fi
    fi
}

# Detect operating system
detect_os() {
    log_step "Detecting Operating System"
    
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$NAME
        OS_VERSION=$VERSION_ID
        log_info "Detected: $OS $OS_VERSION"
    else
        log_error "Cannot detect OS"
        exit 1
    fi

    case $ID in
        ubuntu|debian)
            PKG_MANAGER="apt"
            ;;
        centos|rhel|fedora)
            PKG_MANAGER="yum"
            if command -v dnf &> /dev/null; then
                PKG_MANAGER="dnf"
            fi
            ;;
        *)
            log_error "Unsupported OS: $OS"
            exit 1
            ;;
    esac
    
    log_info "Package manager: $PKG_MANAGER"
}

# Update system packages
update_packages() {
    log_step "Updating System Packages"
    
    case $PKG_MANAGER in
        apt)
            $SUDO apt update -y && $SUDO apt upgrade -y
            ;;
        yum|dnf)
            $SUDO $PKG_MANAGER update -y
            ;;
    esac
    
    if [ $? -eq 0 ]; then
        log_success "System packages updated successfully"
    else
        log_warning "Package update completed with warnings"
    fi
}

# Install required dependencies
install_dependencies() {
    log_step "Installing Required Dependencies"
    
    # Check and install Nginx
    if ! command -v nginx &> /dev/null; then
        log_info "Installing Nginx..."
        case $PKG_MANAGER in
            apt)
                $SUDO apt install -y nginx
                ;;
            yum|dnf)
                $SUDO $PKG_MANAGER install -y nginx
                ;;
        esac
        
        if [ $? -eq 0 ]; then
            $SUDO systemctl enable nginx
            $SUDO systemctl start nginx
            log_success "Nginx installed and started"
        else
            log_error "Failed to install Nginx"
            exit 1
        fi
    else
        log_info "Nginx is already installed"
    fi

    # Check and install Certbot
    if ! command -v certbot &> /dev/null; then
        log_info "Installing Certbot..."
        case $PKG_MANAGER in
            apt)
                $SUDO apt install -y certbot python3-certbot-nginx
                ;;
            yum|dnf)
                if [[ "$ID" == "fedora" ]]; then
                    $SUDO dnf install -y certbot python3-certbot-nginx
                else
                    $SUDO yum install -y epel-release
                    $SUDO yum install -y certbot python3-certbot-nginx
                fi
                ;;
        esac
        
        if [ $? -eq 0 ]; then
            log_success "Certbot installed successfully"
        else
            log_error "Failed to install Certbot"
            exit 1
        fi
    else
        log_info "Certbot is already installed"
    fi

    # Install additional tools
    log_info "Installing additional tools..."
    case $PKG_MANAGER in
        apt)
            $SUDO apt install -y curl dnsutils net-tools
            ;;
        yum|dnf)
            $SUDO $PKG_MANAGER install -y curl bind-utils net-tools
            ;;
    esac
}

# Get user input for domain setup
get_user_input() {
    log_step "Domain Configuration"
    
    echo -e "${CYAN}┌────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│                  Domain Setup Options                     │${NC}"
    echo -e "${CYAN}└────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    
    # Domain option selection
    echo -e "${YELLOW}Select domain type:${NC}"
    echo "  1) Full domain (example.com)"
    echo "  2) Subdomain (sub.example.com)"
    echo -e "  3) Wildcard domain (*.example.com) ${YELLOW}(requires DNS validation)${NC}"
    echo ""
    
    while true; do
        read -p "Enter choice [1-3]: " DOMAIN_CHOICE
        case $DOMAIN_CHOICE in
            1)
                while true; do
                    read -p "Enter domain (e.g., example.com): " DOMAIN
                    if [[ -n "$DOMAIN" && "$DOMAIN" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
                        FULL_DOMAIN="$DOMAIN"
                        break
                    else
                        log_error "Invalid domain format. Please enter like: example.com"
                    fi
                done
                break
                ;;
            2)
                while true; do
                    read -p "Enter subdomain (e.g., blog): " SUBDOMAIN
                    if [[ -n "$SUBDOMAIN" && "$SUBDOMAIN" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]]; then
                        break
                    else
                        log_error "Invalid subdomain format"
                    fi
                done
                
                while true; do
                    read -p "Enter domain (e.g., example.com): " DOMAIN
                    if [[ -n "$DOMAIN" && "$DOMAIN" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
                        FULL_DOMAIN="$SUBDOMAIN.$DOMAIN"
                        break
                    else
                        log_error "Invalid domain format"
                    fi
                done
                break
                ;;
            3)
                log_warning "Wildcard certificates require DNS validation method"
                log_info "You'll need to manually add TXT records when prompted by Certbot"
                while true; do
                    read -p "Enter domain for wildcard (e.g., example.com): " DOMAIN
                    if [[ -n "$DOMAIN" && "$DOMAIN" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
                        FULL_DOMAIN="$DOMAIN"
                        WILDCARD=true
                        break
                    else
                        log_error "Invalid domain format"
                    fi
                done
                break
                ;;
            *)
                log_error "Invalid choice. Please enter 1, 2, or 3"
                ;;
        esac
    done
    
    log_info "Target domain: $FULL_DOMAIN"
    
    # Ask for admin email
    echo ""
    read -p "Enter admin email for SSL notifications [admin@$DOMAIN]: " LE_EMAIL
    LE_EMAIL=${LE_EMAIL:-admin@$DOMAIN}
}

# Validate DNS configuration
validate_dns() {
    log_step "DNS Validation"
    
    log_info "Checking DNS for $FULL_DOMAIN..."
    
    # Function to get public IP
    get_public_ip() {
        local ip_services=(
            "https://api.ipify.org"
            "https://icanhazip.com"
            "https://checkip.amazonaws.com"
            "https://ifconfig.me/ip"
        )
        
        for service in "${ip_services[@]}"; do
            local ip=$(curl -s -4 --max-time 5 "$service" 2>/dev/null | tr -d '[:space:]')
            if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                echo "$ip"
                return 0
            fi
        done
        
        return 1
    }
    
    # Get server IP
    SERVER_IP=$(get_public_ip)
    
    if [[ -z "$SERVER_IP" ]]; then
        # Try alternative method
        SERVER_IP=$(curl -s -4 --max-time 10 "https://ifconfig.co" 2>/dev/null | tr -d '[:space:]')
    fi
    
    if [[ -z "$SERVER_IP" ]]; then
        log_error "Cannot determine server public IP"
        read -p "Please enter server IP manually: " SERVER_IP
        if [[ ! $SERVER_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            log_error "Invalid IP address format"
            exit 1
        fi
    fi
    
    log_info "Server public IP: $SERVER_IP"
    
    # Check DNS resolution
    DNS_IP=$(dig +short A "$FULL_DOMAIN" | head -n1)
    
    if [[ -z "$DNS_IP" ]]; then
        # Try nslookup as fallback
        DNS_IP=$(nslookup "$FULL_DOMAIN" 2>/dev/null | grep -A1 "Name:" | grep "Address:" | awk '{print $2}' | head -n1)
    fi
    
    if [[ -z "$DNS_IP" ]]; then
        log_warning "Cannot resolve $FULL_DOMAIN"
        echo -e "\n${YELLOW}DNS Configuration Required:${NC}"
        echo "────────────────────────────────"
        echo "Please add this DNS record in your domain control panel:"
        echo ""
        echo -e "${CYAN}Type:${NC} A"
        echo -e "${CYAN}Name:${NC} ${FULL_DOMAIN}"
        echo -e "${CYAN}Value:${NC} ${SERVER_IP}"
        echo -e "${CYAN}TTL:${NC} 3600"
        echo ""
        
        if [[ "$WILDCARD" == "true" ]]; then
            echo -e "${YELLOW}For wildcard certificate, you'll also need:${NC}"
            echo "Type: TXT"
            echo "Name: _acme-challenge.${FULL_DOMAIN}"
            echo "Value: [Will be provided by Certbot]"
        fi
        
        read -p "Press Enter when DNS is configured, or 's' to skip DNS check: " SKIP_DNS
        if [[ "$SKIP_DNS" != "s" ]]; then
            log_info "Waiting 30 seconds for DNS propagation..."
            sleep 30
            DNS_IP=$(dig +short A "$FULL_DOMAIN" | head -n1)
        fi
    fi
    
    if [[ -n "$DNS_IP" ]]; then
        log_info "DNS resolved IP: $DNS_IP"
        
        if [[ "$DNS_IP" == "$SERVER_IP" ]]; then
            log_success "DNS validation passed"
        else
            log_warning "DNS IP ($DNS_IP) doesn't match server IP ($SERVER_IP)"
            echo -e "\n${YELLOW}Please update your DNS A record:${NC}"
            echo "$FULL_DOMAIN → $SERVER_IP"
            read -p "Continue anyway? (y/n): " CONTINUE
            if [[ ! $CONTINUE =~ ^[Yy]$ ]]; then
                exit 1
            fi
        fi
    else
        log_warning "Skipping DNS validation"
    fi
}

# Setup initial Nginx configuration for SSL challenge
setup_nginx_initial() {
    log_step "Configuring Nginx for SSL"
    
    # Create necessary directories
    $SUDO mkdir -p /var/www/html/.well-known/acme-challenge
    
    # Backup existing config if it exists
    NGINX_CONF="/etc/nginx/sites-available/$FULL_DOMAIN"
    if [[ -f "$NGINX_CONF" ]]; then
        $SUDO cp "$NGINX_CONF" "$NGINX_CONF.backup.$(date +%Y%m%d_%H%M%S)"
        log_info "Backed up existing configuration"
    fi
    
    # Create initial Nginx configuration
    $SUDO tee "$NGINX_CONF" > /dev/null <<EOF
# Initial configuration for SSL certificate validation
server {
    listen 80;
    server_name $FULL_DOMAIN;
    
    # Let's Encrypt challenge directory
    location /.well-known/acme-challenge/ {
        root /var/www/html;
        allow all;
    }
    
    # Redirect all other traffic to HTTPS (will be active after SSL)
    location / {
        return 301 https://\$server_name\$request_uri;
    }
}
EOF
    
    # Enable site
    if [[ ! -f "/etc/nginx/sites-enabled/$FULL_DOMAIN" ]]; then
        $SUDO ln -sf "$NGINX_CONF" "/etc/nginx/sites-enabled/"
    fi
    
    # Test Nginx configuration
    log_info "Testing Nginx configuration..."
    if $SUDO nginx -t; then
        $SUDO systemctl reload nginx
        log_success "Nginx configuration applied successfully"
    else
        log_error "Nginx configuration test failed"
        exit 1
    fi
}

# Obtain SSL certificate from Let's Encrypt
obtain_ssl() {
    log_step "Obtaining SSL Certificate"
    
    if [[ "$WILDCARD" == "true" ]]; then
        log_info "Requesting wildcard certificate for *.$FULL_DOMAIN"
        log_warning "This requires DNS validation with TXT records"
        echo ""
        if $SUDO certbot certonly --manual \
            --preferred-challenges=dns \
            --manual-public-ip-logging-ok \
            -d "*.$FULL_DOMAIN" \
            -d "$FULL_DOMAIN" \
            --non-interactive \
            --agree-tos \
            --email "$LE_EMAIL"; then
            log_success "Wildcard SSL certificate obtained successfully"
        else
            log_error "Failed to obtain wildcard certificate"
            log_info "You may need to manually add TXT DNS records"
            exit 1
        fi
    else
        log_info "Requesting SSL certificate for $FULL_DOMAIN"
        
        # Try with --nginx plugin first
        if $SUDO certbot --nginx \
            -d "$FULL_DOMAIN" \
            --non-interactive \
            --agree-tos \
            --email "$LE_EMAIL" \
            --redirect \
            --hsts; then
            log_success "SSL certificate obtained and configured successfully"
        else
            log_warning "Certbot with nginx plugin failed, trying standalone method..."
            
            # Stop nginx temporarily for standalone mode
            $SUDO systemctl stop nginx
            
            if $SUDO certbot certonly --standalone \
                -d "$FULL_DOMAIN" \
                --non-interactive \
                --agree-tos \
                --email "$LE_EMAIL"; then
                log_success "SSL certificate obtained via standalone method"
            else
                log_error "Failed to obtain SSL certificate"
                $SUDO systemctl start nginx
                exit 1
            fi
            
            # Restart nginx
            $SUDO systemctl start nginx
        fi
    fi
}

# Setup application forwarding
setup_app_forwarding() {
    log_step "Application Configuration"
    
    echo -e "\n${CYAN}┌────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│                Application Forwarding                    │${NC}"
    echo -e "${CYAN}└────────────────────────────────────────────────────────────┘${NC}"
    
    read -p "Do you want to forward HTTPS traffic to a local application? (y/n): " FORWARD_APP
    
    if [[ $FORWARD_APP =~ ^[Yy]$ ]]; then
        # Get application details
        echo ""
        log_info "Enter application details:"
        
        while true; do
            read -p "Application port (e.g., 3000, 8080, 5650): " APP_PORT
            if [[ $APP_PORT =~ ^[0-9]+$ ]] && [ $APP_PORT -ge 1 ] && [ $APP_PORT -le 65535 ]; then
                break
            else
                log_error "Invalid port number. Must be between 1 and 65535"
            fi
        done
        
        read -p "Application host/IP [127.0.0.1]: " APP_HOST
        APP_HOST=${APP_HOST:-127.0.0.1}
        
        read -p "Application protocol (http/https/ws) [http]: " APP_PROTOCOL
        APP_PROTOCOL=${APP_PROTOCOL:-http}
        
        # Create comprehensive Nginx configuration
        $SUDO tee "/etc/nginx/sites-available/$FULL_DOMAIN" > /dev/null <<EOF
# SSL Configuration for $FULL_DOMAIN
# Generated on $(date)
# Certificate: /etc/letsencrypt/live/$FULL_DOMAIN/

# HTTP to HTTPS redirect
server {
    listen 80;
    listen [::]:80;
    server_name $FULL_DOMAIN;
    
    # ACME challenge location
    location /.well-known/acme-challenge/ {
        root /var/www/html;
        allow all;
    }
    
    # Redirect everything else to HTTPS
    location / {
        return 301 https://\$server_name\$request_uri;
    }
    
    access_log /var/log/nginx/${FULL_DOMAIN}_access.log;
    error_log /var/log/nginx/${FULL_DOMAIN}_error.log;
}

# HTTPS server
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $FULL_DOMAIN;
    
    # SSL certificate paths
    ssl_certificate /etc/letsencrypt/live/$FULL_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$FULL_DOMAIN/privkey.pem;
    
    # SSL security settings
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_stapling on;
    ssl_stapling_verify on;
    
    # Security headers
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    add_header X-Frame-Options DENY always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    
    # Root location (can be used for static files)
    location / {
        # Uncomment for static file serving:
        # root /var/www/html;
        # index index.html;
        
        # Reverse proxy configuration
        proxy_pass ${APP_PROTOCOL}://${APP_HOST}:${APP_PORT};
        
        # Proxy headers
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        
        # Timeouts
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        
        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
    
    # Block access to hidden files
    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }
    
    # Security: deny access to sensitive files
    location ~ /(\.git|\.env|\.htaccess|\.htpasswd) {
        deny all;
        access_log off;
        log_not_found off;
    }
    
    # Optional: Add specific API or static file locations here
    # location /api/ {
    #     proxy_pass http://127.0.0.1:8000;
    # }
    
    # location /static/ {
    #     root /var/www/static;
    #     expires 1y;
    #     add_header Cache-Control "public, immutable";
    # }
    
    access_log /var/log/nginx/${FULL_DOMAIN}_ssl_access.log;
    error_log /var/log/nginx/${FULL_DOMAIN}_ssl_error.log;
}
EOF
        
        # Test configuration
        log_info "Testing updated Nginx configuration..."
        if $SUDO nginx -t; then
            $SUDO systemctl reload nginx
            log_success "Application forwarding configured successfully"
            echo ""
            echo -e "${GREEN}✓ Forwarding configured:${NC}"
            echo "  https://$FULL_DOMAIN → ${APP_PROTOCOL}://${APP_HOST}:${APP_PORT}"
        else
            log_error "Nginx configuration test failed"
            exit 1
        fi
    else
        log_info "Skipping application forwarding setup"
        log_info "You can manually edit /etc/nginx/sites-available/$FULL_DOMAIN later"
    fi
}

# Setup automatic certificate renewal
setup_auto_renewal() {
    log_step "Configuring Auto-Renewal"
    
    # Test renewal process
    log_info "Testing certificate renewal..."
    if $SUDO certbot renew --dry-run; then
        log_success "Auto-renewal test passed"
    else
        log_warning "Auto-renewal test failed. Manual renewal may be required"
    fi
    
    # Add cron job if not exists
    CRON_JOB="0 12 * * * /usr/bin/certbot renew --quiet --post-hook \"systemctl reload nginx\""
    if ! crontab -l 2>/dev/null | grep -q "certbot renew"; then
        (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
        log_success "Auto-renewal cron job added"
    else
        log_info "Auto-renewal cron job already exists"
    fi
    
    # Add renewal hook for nginx reload
    $SUDO mkdir -p /etc/letsencrypt/renewal-hooks/post
    $SUDO tee /etc/letsencrypt/renewal-hooks/post/reload-nginx.sh > /dev/null <<EOF
#!/bin/bash
systemctl reload nginx
EOF
    $SUDO chmod +x /etc/letsencrypt/renewal-hooks/post/reload-nginx.sh
}

# Final verification and summary
final_verification() {
    log_step "Final Verification"
    
    echo -e "\n${CYAN}┌────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│                    Verification Results                   │${NC}"
    echo -e "${CYAN}└────────────────────────────────────────────────────────────┘${NC}"
    
    # Check certificate status
    log_info "Certificate status:"
    if $SUDO certbot certificates | grep -A 3 "$FULL_DOMAIN"; then
        log_success "✓ SSL certificate is valid"
    else
        log_error "✗ SSL certificate not found"
    fi
    
    # Check Nginx configuration
    log_info "\nNginx configuration:"
    if $SUDO nginx -t 2>&1 | grep -q "successful"; then
        log_success "✓ Nginx configuration is valid"
    else
        log_error "✗ Nginx configuration has errors"
    fi
    
    # Test HTTPS connection
    log_info "\nTesting HTTPS connection..."
    echo -e "${YELLOW}Attempting to connect to https://$FULL_DOMAIN ...${NC}"
    
    RESPONSE=$(curl -s -o /dev/null -w "%{http_code}\n%{time_total}" "https://$FULL_DOMAIN" --max-time 10 2>/dev/null || echo "000")
    HTTP_CODE=$(echo "$RESPONSE" | head -n1)
    RESPONSE_TIME=$(echo "$RESPONSE" | tail -n1)
    
    if [[ "$HTTP_CODE" =~ ^[23][0-9][0-9]$ ]]; then
        log_success "✓ HTTPS connection successful (HTTP $HTTP_CODE, ${RESPONSE_TIME}s)"
    elif [[ "$HTTP_CODE" == "000" ]]; then
        log_warning "⚠ Could not connect (service may not be running)"
    else
        log_warning "⚠ HTTPS returned HTTP $HTTP_CODE"
    fi
    
    # Display summary
    echo -e "\n${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                 SETUP COMPLETED SUCCESSFULLY                ${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}┌────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│                        Summary                           │${NC}"
    echo -e "${CYAN}└────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "${YELLOW}Domain:${NC}          https://$FULL_DOMAIN"
    echo -e "${YELLOW}Certificate:${NC}     /etc/letsencrypt/live/$FULL_DOMAIN/"
    echo -e "${YELLOW}Nginx Config:${NC}    /etc/nginx/sites-available/$FULL_DOMAIN"
    echo -e "${YELLOW}Logs:${NC}            /var/log/nginx/${FULL_DOMAIN}_*.log"
    echo ""
    
    if [[ $FORWARD_APP =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Forwarding:${NC}      https://$FULL_DOMAIN → ${APP_PROTOCOL}://${APP_HOST}:${APP_PORT}"
        echo ""
        echo -e "${CYAN}Application Command Examples:${NC}"
        echo "  # Python Flask"
        echo "  python3 app.py"
        echo ""
        echo "  # Node.js"
        echo "  npm start"
        echo ""
        echo "  # Run in background"
        echo "  nohup python3 app.py > app.log 2>&1 &"
    fi
    
    echo -e "${CYAN}Useful Commands:${NC}"
    echo "  Check certificate: sudo certbot certificates"
    echo "  Renew certificate: sudo certbot renew"
    echo "  Test Nginx config: sudo nginx -t"
    echo "  Reload Nginx:      sudo systemctl reload nginx"
    echo "  View logs:         sudo tail -f /var/log/nginx/${FULL_DOMAIN}_error.log"
    echo ""
    echo -e "${GREEN}✅ SSL setup is complete! Your site is now secured.${NC}"
}

# Main execution flow
main() {
    show_banner
    
    echo -e "${YELLOW}This script will:${NC}"
    echo " 1. Install Nginx and Certbot"
    echo " 2. Configure SSL for your domain"
    echo " 3. Set up HTTPS redirection"
    echo " 4. Optionally configure application forwarding"
    echo ""
    
    read -p "Continue with SSL setup? (y/n): " CONFIRM
    if [[ ! $CONFIRM =~ ^[Yy]$ ]]; then
        echo "Setup cancelled"
        exit 0
    fi
    
    # Execute steps
    check_privileges
    detect_os
    update_packages
    install_dependencies
    get_user_input
    validate_dns
    setup_nginx_initial
    obtain_ssl
    setup_app_forwarding
    setup_auto_renewal
    final_verification
}

# Trap for clean exit
trap 'log_error "Script interrupted by user"; exit 1' INT

# Run main function
main "$@"
