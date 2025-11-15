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

# Check if running as root or with sudo
check_privileges() {
    if [[ $EUID -eq 0 ]]; then
        log_info "Running as root user"
        SUDO=""
    else
        # Check if user has sudo privileges
        if sudo -n true 2>/dev/null; then
            log_info "Running with sudo privileges"
            SUDO="sudo"
        else
            log_error "This script requires root privileges"
            log_info "Please run as root or with sudo privileges"
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

# Create Nginx configuration
setup_nginx() {
    log_info "Setting up Nginx configuration..."
    
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
    log_success "Nginx configuration applied"
}

# Obtain SSL certificate
obtain_ssl() {
    log_info "Obtaining SSL certificate for $FULL_DOMAIN..."
    
    if $SUDO certbot --nginx -d "$FULL_DOMAIN" --non-interactive --agree-tos --email admin@"$DOMAIN" --redirect; then
        log_success "SSL certificate obtained successfully"
    else
        log_error "Failed to obtain SSL certificate"
        exit 1
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
    
    # Test HTTPS
    if curl -s -I "https://$FULL_DOMAIN" | grep -q "200"; then
        log_success "HTTPS is working correctly"
    else
        log_warning "HTTPS test inconclusive, but setup completed"
    fi
    
    echo
    log_success "🎉 SSL setup completed successfully!"
    log_info "Your domain https://$FULL_DOMAIN is now secured with SSL"
    echo
    log_info "Certificate location: /etc/letsencrypt/live/$FULL_DOMAIN/"
    log_info "Nginx config: /etc/nginx/sites-available/$FULL_DOMAIN"
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
    setup_nginx
    obtain_ssl
    setup_auto_renewal
    final_verification
}

# Run main function
main "$@"
