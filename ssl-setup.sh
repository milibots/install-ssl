#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check privileges - ALLOW root for SSL setup
check_privileges() {
    if [[ $EUID -eq 0 ]]; then
        log_info "Running as root - required for SSL setup"
        SUDO=""
    else
        # Check if user has sudo privileges
        if sudo -n true 2>/dev/null; then
            log_info "Running with sudo privileges"
            SUDO="sudo"
        else
            log_error "This script requires root privileges for SSL setup"
            log_info "Please run with: sudo bash ssl-setup.sh"
            exit 1
        fi
    fi
}

# Detect OS and package manager
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$NAME
        OS_VERSION=$VERSION_ID
    else
        log_error "Cannot detect OS"
        exit 1
    fi

    case $ID in
        ubuntu|debian)
            PKG_MANAGER="apt"
            log_info "Detected OS: $OS (Debian-based)"
            ;;
        centos|rhel|fedora)
            PKG_MANAGER="yum"
            if command -v dnf &> /dev/null; then
                PKG_MANAGER="dnf"
            fi
            log_info "Detected OS: $OS (RHEL-based)"
            ;;
        *)
            log_error "Unsupported OS: $OS"
            exit 1
            ;;
    esac
}

# Update package manager
update_packages() {
    log_info "Updating package lists..."
    case $PKG_MANAGER in
        apt)
            $SUDO apt update -y
            ;;
        yum|dnf)
            $SUDO $PKG_MANAGER update -y
            ;;
    esac
}

# Install dependencies
install_dependencies() {
    log_info "Installing dependencies..."
    
    # Check if nginx is installed
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
        # Start and enable nginx
        $SUDO systemctl enable nginx
        $SUDO systemctl start nginx
    else
        log_info "Nginx is already installed"
    fi

    # Check if certbot is installed
    if ! command -v certbot &> /dev/null; then
        log_info "Installing Certbot..."
        case $PKG_MANAGER in
            apt)
                $SUDO apt install -y certbot python3-certbot-nginx
                ;;
            yum|dnf)
                $SUDO $PKG_MANAGER install -y certbot python3-certbot-nginx
                ;;
        esac
    else
        log_info "Certbot is already installed"
    fi

    # Install other dependencies
    case $PKG_MANAGER in
        apt)
            $SUDO apt install -y curl dnsutils
            ;;
        yum|dnf)
            $SUDO $PKG_MANAGER install -y curl bind-utils
            ;;
    esac
}

# Get user input
get_user_input() {
    echo
    log_info "SSL Certificate Setup for Nginx"
    echo "======================================"
    
    while true; do
        read -p "Enter subdomain (e.g., bot): " SUBDOMAIN
        if [[ -n "$SUBDOMAIN" ]]; then
            break
        else
            log_error "Subdomain cannot be empty"
        fi
    done

    while true; do
        read -p "Enter domain (e.g., godsetta.org): " DOMAIN
        if [[ -n "$DOMAIN" ]]; then
            break
        else
            log_error "Domain cannot be empty"
        fi
    done

    FULL_DOMAIN="$SUBDOMAIN.$DOMAIN"
    log_info "Target domain: $FULL_DOMAIN"
}

# Validate DNS
validate_dns() {
    log_info "Validating DNS for $FULL_DOMAIN..."
    
    # Get current server public IP
    SERVER_IP=$(curl -s -4 ifconfig.co)
    if [[ -z "$SERVER_IP" ]]; then
        SERVER_IP=$(curl -s -4 icanhazip.com)
    fi
    
    log_info "Server public IP: $SERVER_IP"
    
    # Get DNS IP
    DNS_IP=$(nslookup "$FULL_DOMAIN" | grep -A1 "Name:" | grep "Address:" | awk '{print $2}' | head -n1)
    
    if [[ -z "$DNS_IP" ]]; then
        log_error "Cannot resolve $FULL_DOMAIN"
        log_warning "Please make sure your DNS is configured correctly:"
        echo "  $FULL_DOMAIN A $SERVER_IP"
        exit 1
    fi
    
    log_info "DNS resolved IP: $DNS_IP"
    
    if [[ "$DNS_IP" != "$SERVER_IP" ]]; then
        log_error "DNS IP ($DNS_IP) does not match server IP ($SERVER_IP)"
        log_warning "Please update your DNS records:"
        echo "  $FULL_DOMAIN A $SERVER_IP"
        exit 1
    fi
    
    log_success "DNS validation passed"
}

# Create initial Nginx configuration for SSL challenge
setup_nginx_initial() {
    log_info "Setting up initial Nginx configuration for SSL challenge..."
    
    # Create nginx config
    NGINX_CONF="/etc/nginx/sites-available/$FULL_DOMAIN"
    
    $SUDO tee "$NGINX_CONF" > /dev/null <<EOF
server {
    listen 80;
    server_name $FULL_DOMAIN;
    
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
    
    location / {
        return 301 https://\$server_name\$request_uri;
    }
}
EOF

    # Enable site
    if [[ ! -f "/etc/nginx/sites-enabled/$FULL_DOMAIN" ]]; then
        $SUDO ln -s "$NGINX_CONF" "/etc/nginx/sites-enabled/"
    fi
    
    # Test nginx configuration
    log_info "Testing Nginx configuration..."
    if ! $SUDO nginx -t; then
        log_error "Nginx configuration test failed"
        exit 1
    fi
    
    # Reload nginx
    $SUDO systemctl reload nginx
    log_success "Initial Nginx configuration applied"
}

# Obtain SSL certificate
obtain_ssl() {
    log_info "Obtaining SSL certificate for $FULL_DOMAIN..."
    
    # Generate a random email for Let's Encrypt
    LE_EMAIL="admin@$DOMAIN"
    
    if $SUDO certbot --nginx -d "$FULL_DOMAIN" --non-interactive --agree-tos --email "$LE_EMAIL" --redirect; then
        log_success "SSL certificate obtained successfully"
    else
        log_error "Failed to obtain SSL certificate"
        log_info "Trying alternative method..."
        # Alternative method - certonly first, then we'll set up the config manually
        if $SUDO certbot certonly --nginx -d "$FULL_DOMAIN" --non-interactive --agree-tos --email "$LE_EMAIL"; then
            log_success "SSL certificate obtained via certonly"
        else
            log_error "Failed to obtain SSL certificate completely"
            exit 1
        fi
    fi
}

# Setup application forwarding with proper SSL config
setup_app_forwarding() {
    echo
    log_info "Application Forwarding Setup"
    echo "================================"
    
    read -p "Do you want to forward traffic to a local application? (y/n): " FORWARD_APP
    
    if [[ $FORWARD_APP =~ ^[Yy]$ ]]; then
        while true; do
            read -p "Enter application port (e.g., 5650): " APP_PORT
            if [[ $APP_PORT =~ ^[0-9]+$ ]] && [ $APP_PORT -ge 1 ] && [ $APP_PORT -le 65535 ]; then
                break
            else
                log_error "Please enter a valid port number (1-65535)"
            fi
        done
        
        read -p "Enter application host (default: 127.0.0.1): " APP_HOST
        APP_HOST=${APP_HOST:-127.0.0.1}
        
        log_info "Setting up forwarding from https://$FULL_DOMAIN to $APP_HOST:$APP_PORT"
        
        # Create a COMPLETE new nginx configuration that includes both HTTP and HTTPS
        $SUDO tee "/etc/nginx/sites-available/$FULL_DOMAIN" > /dev/null <<EOF
# HTTP redirect to HTTPS
server {
    listen 80;
    server_name $FULL_DOMAIN;
    
    # ACME challenge for certificate renewal
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
    
    # Redirect everything else to HTTPS
    location / {
        return 301 https://\$server_name\$request_uri;
    }
}

# HTTPS server with proxy
server {
    listen 443 ssl http2;
    server_name $FULL_DOMAIN;
    
    # SSL certificates
    ssl_certificate /etc/letsencrypt/live/$FULL_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$FULL_DOMAIN/privkey.pem;
    
    # SSL security settings
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    
    # Security headers
    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    
    # Proxy settings
    location / {
        proxy_pass http://$APP_HOST:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        
        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        # Timeouts
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
    
    # Block access to hidden files
    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }
}
EOF
        
        # Test nginx configuration
        log_info "Testing updated Nginx configuration..."
        if ! $SUDO nginx -t; then
            log_error "Nginx configuration test failed after adding proxy"
            log_info "Let's check the current nginx config for $FULL_DOMAIN:"
            $SUDO nginx -T | grep -A 50 "server_name $FULL_DOMAIN" || true
            exit 1
        fi
        
        # Reload nginx
        $SUDO systemctl reload nginx
        log_success "Application forwarding configured"
        log_info "All traffic to https://$FULL_DOMAIN will be forwarded to $APP_HOST:$APP_PORT"
        
        # Show example command to run the application
        echo
        log_info "Example command to run your application:"
        echo "  python3 app.py  # Make sure it binds to $APP_HOST:$APP_PORT"
        echo
        log_warning "IMPORTANT: Make sure your Flask app is running and accessible at http://$APP_HOST:$APP_PORT"
        
    else
        log_info "Skipping application forwarding setup"
    fi
}

# Setup auto-renewal
setup_auto_renewal() {
    log_info "Setting up auto-renewal..."
    
    # Test renewal
    if $SUDO certbot renew --dry-run; then
        log_success "Auto-renewal test successful"
    else
        log_warning "Auto-renewal test failed, but continuing"
    fi
    
    # Add cron job if not exists
    CRON_JOB="0 12 * * * /usr/bin/certbot renew --quiet"
    if ! $SUDO crontab -l 2>/dev/null | grep -q "certbot renew"; then
        ($SUDO crontab -l 2>/dev/null; echo "$CRON_JOB") | $SUDO crontab -
        log_success "Auto-renewal cron job added"
    else
        log_info "Auto-renewal cron job already exists"
    fi
}

# Debug current configuration
debug_configuration() {
    log_info "Debugging current configuration..."
    
    echo
    log_info "Current Nginx configuration for $FULL_DOMAIN:"
    echo "=================================================="
    $SUDO nginx -T | grep -A 30 "server_name $FULL_DOMAIN" || log_warning "No configuration found for $FULL_DOMAIN"
    
    echo
    log_info "Checking if certificate exists:"
    $SUDO certbot certificates | grep -A 10 "$FULL_DOMAIN" || log_warning "No certificate found for $FULL_DOMAIN"
    
    echo
    log_info "Testing HTTPS connection:"
    if curl -s -I "https://$FULL_DOMAIN" --max-time 10 | head -n 5; then
        log_success "HTTPS connection successful"
    else
        log_warning "HTTPS connection test failed or timed out"
    fi
}

# Final verification
final_verification() {
    log_info "Performing final verification..."
    
    # Check if SSL certificate is valid
    if $SUDO certbot certificates | grep -q "$FULL_DOMAIN"; then
        log_success "SSL certificate verified"
    else
        log_error "SSL certificate verification failed"
        exit 1
    fi
    
    # Test HTTPS with more detailed output
    log_info "Testing HTTPS access to $FULL_DOMAIN..."
    RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" "https://$FULL_DOMAIN" --max-time 10)
    
    if [[ "$RESPONSE" =~ ^[23][0-9][0-9]$ ]]; then
        log_success "HTTPS is working correctly (HTTP $RESPONSE)"
    else
        log_warning "HTTPS returned HTTP $RESPONSE - this might be normal if your app isn't running yet"
    fi
    
    echo
    log_success "🎉 SSL setup completed successfully!"
    log_info "Your domain https://$FULL_DOMAIN is now secured with SSL"
    echo
    log_info "Certificate location: /etc/letsencrypt/live/$FULL_DOMAIN/"
    log_info "Nginx config: /etc/nginx/sites-available/$FULL_DOMAIN"
    
    # Run debug to show current state
    debug_configuration
}

# Main execution
main() {
    clear
    log_info "Starting SSL setup automation..."
    
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

# Run main function
main "$@"
