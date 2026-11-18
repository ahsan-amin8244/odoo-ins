#!/bin/bash
set -e

# =========================================
# Odoo Community Edition Auto Installer
# Optional Worker Mode + Nginx (only if workers enabled)
# Service name: odoo
# =========================================

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_msg() { echo -e "${GREEN}========== $1 ==========${NC}"; }
print_warning() { echo -e "${YELLOW}[WARNING] $1${NC}"; }
print_error() { echo -e "${RED}[ERROR] $1${NC}"; }

get_input() {
    local prompt=$1
    local default=$2
    local var_name=$3

    read -p "$prompt [$default]: " input
    eval "$var_name=${input:-$default}"
}

get_password() {
    local prompt=$1
    local var_name=$2

    read -sp "$prompt: " input
    echo
    printf -v "$var_name" '%s' "$input"
}

get_cpu_cores() { nproc; }

normalize_yesno() {
    local v
    v="$(echo "$1" | tr '[:upper:]' '[:lower:]' | xargs)"
    case "$v" in
        y|yes|true|1) echo "yes" ;;
        *) echo "no" ;;
    esac
}

echo "==========================================="
echo "   Odoo Installation Configuration"
echo "==========================================="
echo ""

# Core inputs
get_input "Enter Odoo system username" "odoo" ODOO_USER
get_input "Enter Odoo installation directory" "/opt/odoo" ODOO_HOME
get_input "Enter Odoo version/branch" "18.0" ODOO_VERSION
get_input "Enter PostgreSQL database user" "odoo" DB_USER
get_password "Enter PostgreSQL database password" DB_PASSWORD
echo ""
get_password "Set Linux Odoo user password (for SSH login)" ODOO_USER_PASSWORD
echo ""
get_password "Enter Odoo master/admin password" ADMIN_PASSWORD
echo ""

# Ask about worker mode
get_input "Enable Odoo worker mode? (yes/no)" "yes" WORKER_MODE_INPUT
WORKER_MODE="$(normalize_yesno "$WORKER_MODE_INPUT")"

# Ports (always need Odoo port)
get_input "Enter Odoo internal port" "8069" ODOO_PORT

# Worker mode only questions (includes nginx)1 811 105 932
DOMAIN_NAME=""
NGINX_HTTP_PORT="80"
GEVENT_PORT="8072"
WORKERS=""
MAX_CRON_THREADS=""
LIMIT_MEMORY_SOFT="2048"
LIMIT_MEMORY_HARD="2560"
LIMIT_TIME_CPU="60"
LIMIT_TIME_REAL="120"

if [ "$WORKER_MODE" = "yes" ]; then
    get_input "Enter your domain name (leave empty for IP-based access)" "" DOMAIN_NAME
    CERTBOT_EMAIL=""
    if [ -n "$DOMAIN_NAME" ]; then
        get_input "Enter email for Let's Encrypt certificate notices" "" CERTBOT_EMAIL
        if [ -z "$CERTBOT_EMAIL" ]; then
            print_error "An email address is required to request an SSL certificate."
            exit 1
        fi
    fi

    CPU_CORES=$(get_cpu_cores)
    SUGGESTED_WORKERS=$((CPU_CORES * 2 + 1))
    SUGGESTED_MAX_CRON=$((CPU_CORES / 2))
    [ $SUGGESTED_MAX_CRON -lt 1 ] && SUGGESTED_MAX_CRON=1

    echo ""
    echo "System detected: $CPU_CORES CPU cores"
    get_input "Enter number of Odoo workers" "$SUGGESTED_WORKERS" WORKERS
    get_input "Enter max cron threads" "$SUGGESTED_MAX_CRON" MAX_CRON_THREADS
    get_input "Enter worker memory limit (MB)" "2048" LIMIT_MEMORY_SOFT
    get_input "Enter worker hard memory limit (MB)" "2560" LIMIT_MEMORY_HARD
    get_input "Enter time CPU limit (seconds)" "60" LIMIT_TIME_CPU
    get_input "Enter time real limit (seconds)" "120" LIMIT_TIME_REAL
    get_input "Enter Nginx HTTP port" "80" NGINX_HTTP_PORT
    if [ -n "$DOMAIN_NAME" ] && [ "$NGINX_HTTP_PORT" != "80" ]; then
        print_warning "Let's Encrypt HTTP validation requires public port 80. Using port 80 for this domain."
        NGINX_HTTP_PORT="80"
    fi
    get_input "Enter Odoo longpolling port" "8072" GEVENT_PORT
else
    print_warning "Worker mode disabled. Nginx will NOT be installed and Odoo will be accessed directly on port $ODOO_PORT."
fi

# Derived variables
ODOO_HOME_EXT="$ODOO_HOME/odoo"
CONFIG_FILE="/etc/odoo.conf"
SERVICE_FILE="/etc/systemd/system/odoo.service"
LOG_DIR="/var/log/odoo"
VENV_DIR="$ODOO_HOME/odoo-venv"
WKHTML_URL="https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/wkhtmltox_0.12.6.1-2.jammy_amd64.deb"
NGINX_CONFIG="/etc/nginx/sites-available/odoo"
NGINX_ENABLED="/etc/nginx/sites-enabled/odoo"

echo ""
echo "==========================================="
echo "   Configuration Summary"
echo "==========================================="
echo "Odoo User: $ODOO_USER"
echo "Odoo Home: $ODOO_HOME"
echo "Odoo Version: $ODOO_VERSION"
echo "Database User: $DB_USER"
echo "Worker Mode: $WORKER_MODE"
echo "Odoo Port: $ODOO_PORT"
if [ "$WORKER_MODE" = "yes" ]; then
    echo "Domain: ${DOMAIN_NAME:-IP-based access}"
    echo "Workers: $WORKERS"
    echo "Max Cron Threads: $MAX_CRON_THREADS"
    echo "Longpolling Port: $GEVENT_PORT"
    echo "Nginx HTTP Port: $NGINX_HTTP_PORT"
fi
echo "==========================================="
echo ""
read -p "Proceed with installation? (yes/no): " CONFIRM

if [ "$(normalize_yesno "$CONFIRM")" != "yes" ]; then
    echo "Installation cancelled."
    exit 0
fi

print_msg "Updating system"
sudo apt update -y && sudo apt upgrade -y

print_msg "Installing system dependencies"
BASE_PACKAGES=(
    python3-pip python3-dev python3-venv
    libxml2-dev libxslt1-dev zlib1g-dev libsasl2-dev libldap2-dev
    build-essential libssl-dev libffi-dev libmysqlclient-dev libdbd-pg-perl
    libjpeg-dev libpq-dev libjpeg8-dev liblcms2-dev libblas-dev libatlas-base-dev
    npm postgresql git wget curl
)

if [ "$WORKER_MODE" = "yes" ]; then
    BASE_PACKAGES+=(nginx)
    if [ -n "$DOMAIN_NAME" ]; then
        BASE_PACKAGES+=(certbot python3-certbot-nginx)
    fi
fi

sudo apt install -y "${BASE_PACKAGES[@]}"

print_msg "Installing Node.js tools"
sudo npm install -g less less-plugin-clean-css

print_msg "Creating Odoo system user"
if ! id -u "$ODOO_USER" >/dev/null 2>&1; then
    sudo adduser --system --home="$ODOO_HOME" --shell /bin/bash --group "$ODOO_USER"
else
    sudo usermod --home "$ODOO_HOME" --shell /bin/bash "$ODOO_USER"
fi
# Set the account password without displaying it in the terminal.
printf '%s:%s\n' "$ODOO_USER" "$ODOO_USER_PASSWORD" | sudo chpasswd

print_msg "Cloning Odoo source code"
if [ ! -d "$ODOO_HOME_EXT" ]; then
    sudo -u "$ODOO_USER" git clone https://github.com/odoo/odoo.git --branch "$ODOO_VERSION" --depth 1 "$ODOO_HOME_EXT"
fi

print_msg "Setting up Python virtual environment"
sudo -u "$ODOO_USER" python3 -m venv "$VENV_DIR"
sudo -u "$ODOO_USER" bash -c "source '$VENV_DIR/bin/activate' && pip install -U pip wheel setuptools && pip install -r '$ODOO_HOME_EXT/requirements.txt'"

print_msg "Installing wkhtmltopdf"
if ! command -v wkhtmltopdf >/dev/null 2>&1; then
    wget -q "$WKHTML_URL" -O /tmp/wkhtmltox.deb
    sudo apt install -y /tmp/wkhtmltox.deb
    rm /tmp/wkhtmltox.deb
fi

print_msg "Configuring PostgreSQL"
sudo systemctl enable postgresql
sudo systemctl start postgresql

sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1 || \
    sudo -u postgres psql -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASSWORD' CREATEDB NOSUPERUSER;"
# Ensure existing roles also have only the intended database-creation privilege.
sudo -u postgres psql -c "ALTER ROLE $DB_USER NOSUPERUSER CREATEDB;"

print_msg "Creating Odoo log directory"
sudo mkdir -p "$LOG_DIR"
sudo chown "$ODOO_USER":root "$LOG_DIR"
sudo chmod 755 "$LOG_DIR"

print_msg "Creating Odoo configuration file"
COMMON_CONFIG=$(cat <<EOF
[options]
; Admin password for database operations
admin_passwd = $ADMIN_PASSWORD

; Paths
addons_path = $ODOO_HOME_EXT/addons
data_dir = $ODOO_HOME/.local/share/Odoo

; Logging
logfile = $LOG_DIR/odoo.log
logrotate = True

; Network settings
http_port = $ODOO_PORT

; Request limits
limit_request = 8192
EOF
)

if [ "$WORKER_MODE" = "yes" ]; then
WORKER_CONFIG=$(cat <<EOF

; Reverse proxy
proxy_mode = True

; Longpolling
http_interface = 127.0.0.1
gevent_port = $GEVENT_PORT

; Worker settings
workers = $WORKERS
max_cron_threads = $MAX_CRON_THREADS

; Memory limits (bytes)
limit_memory_soft = $((LIMIT_MEMORY_SOFT * 1024 * 1024))
limit_memory_hard = $((LIMIT_MEMORY_HARD * 1024 * 1024))

; Time limits (in seconds)
limit_time_cpu = $LIMIT_TIME_CPU
limit_time_real = $LIMIT_TIME_REAL
EOF
)
else
WORKER_CONFIG=$(cat <<EOF

; Reverse proxy
proxy_mode = False
EOF
)
fi

sudo bash -c "cat > '$CONFIG_FILE'" <<EOF
$COMMON_CONFIG
$WORKER_CONFIG
EOF

sudo chmod 640 "$CONFIG_FILE"
sudo chown "$ODOO_USER":root "$CONFIG_FILE"

print_msg "Creating systemd service"
sudo bash -c "cat > '$SERVICE_FILE'" <<EOF
[Unit]
Description=Odoo Community Edition
Requires=postgresql.service
After=network.target postgresql.service

[Service]
Type=simple
SyslogIdentifier=odoo
PermissionsStartOnly=true
User=$ODOO_USER
Group=$ODOO_USER
ExecStart=$VENV_DIR/bin/python3 $ODOO_HOME_EXT/odoo-bin -c $CONFIG_FILE
StandardOutput=journal+console
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo chmod 644 "$SERVICE_FILE"
sudo chown root:root "$SERVICE_FILE"

if [ "$WORKER_MODE" = "yes" ]; then
    print_msg "Configuring Nginx as reverse proxy"

    sudo rm -f /etc/nginx/sites-enabled/default

    sudo bash -c "cat > '$NGINX_CONFIG'" <<EOF
upstream odoo {
    server 127.0.0.1:$ODOO_PORT;
}

upstream odoo-gevent {
    server 127.0.0.1:$GEVENT_PORT;
}

# This map must be in the nginx http context.
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen $NGINX_HTTP_PORT;
    server_name ${DOMAIN_NAME:-_};

    access_log /var/log/nginx/odoo-access.log;
    error_log /var/log/nginx/odoo-error.log;

    proxy_read_timeout 720s;
    proxy_connect_timeout 720s;
    proxy_send_timeout 720s;

    client_max_body_size 100M;

    # Common reverse-proxy headers
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Forwarded-Port \$server_port;

    # WebSocket real-time services (Odoo 16+)
    location /websocket {
        proxy_pass http://odoo-gevent;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 720s;
        proxy_send_timeout 720s;
        proxy_buffering off;
        proxy_cache off;
    }

    # Legacy long-polling route for compatibility with older addons/clients
    location /longpolling {
        proxy_pass http://odoo-gevent;
        proxy_http_version 1.1;
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 720s;
        proxy_send_timeout 720s;
        proxy_buffering off;
    }

    # Static files
    location ~* /web/static/ {
        proxy_pass http://odoo;
        proxy_buffering on;
        proxy_cache_valid 200 90m;
        expires 10d;
    }

    # Main Odoo application
    location / {
        proxy_redirect off;
        proxy_pass http://odoo;
        proxy_http_version 1.1;
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_buffering on;
    }

    gzip on;
    gzip_min_length 1000;
    gzip_types
        text/css
        text/scss
        text/plain
        text/xml
        application/xml
        application/json
        application/javascript;
}
EOF

    sudo ln -sf "$NGINX_CONFIG" "$NGINX_ENABLED"

    print_msg "Testing Nginx configuration"
    sudo nginx -t
fi

if command -v ufw >/dev/null 2>&1; then
    if sudo ufw status | grep -q "Status: active"; then
        print_msg "Configuring firewall"
        if [ "$WORKER_MODE" = "yes" ]; then
            sudo ufw allow 'Nginx Full'
        else
            sudo ufw allow "$ODOO_PORT"/tcp
        fi
    fi
fi

print_msg "Reloading and starting services"
sudo systemctl daemon-reload
sudo systemctl enable odoo
sudo systemctl restart odoo

if [ "$WORKER_MODE" = "yes" ]; then
    sudo systemctl restart nginx

    if [ -n "$DOMAIN_NAME" ]; then
        print_msg "Requesting and applying HTTPS certificate"
        sudo certbot --nginx --non-interactive --agree-tos \
            --email "$CERTBOT_EMAIL" --domain "$DOMAIN_NAME" --redirect
    fi
fi

sleep 5

print_msg "Checking Odoo service status"
sudo systemctl status odoo --no-pager -l

if [ "$WORKER_MODE" = "yes" ]; then
    print_msg "Checking Nginx service status"
    sudo systemctl status nginx --no-pager -l
fi

echo ""
echo "==========================================="
echo "   Installation Completed Successfully!"
echo "==========================================="
echo ""
echo "Service Status:"
echo "  Odoo:  $(sudo systemctl is-active odoo)"
if [ "$WORKER_MODE" = "yes" ]; then
    echo "  Nginx: $(sudo systemctl is-active nginx)"
fi
echo ""
echo "Access Information:"
if [ "$WORKER_MODE" = "yes" ]; then
    if [ -n "$DOMAIN_NAME" ]; then
        echo "  URL: http://$DOMAIN_NAME"
    else
        echo "  URL: http://<your_server_ip>"
    fi
else
    echo "  URL: http://<your_server_ip>:$ODOO_PORT"
fi
echo ""
echo "Configuration Files:"
echo "  Odoo Config:  $CONFIG_FILE"
echo "  Service File: $SERVICE_FILE"
if [ "$WORKER_MODE" = "yes" ]; then
    echo "  Nginx Config: $NGINX_CONFIG"
fi
echo ""
echo "Useful Commands:"
echo "  Check Odoo logs:     sudo tail -f $LOG_DIR/odoo.log"
echo "  Restart Odoo:        sudo systemctl restart odoo"
if [ "$WORKER_MODE" = "yes" ]; then
    echo "  Restart Nginx:       sudo systemctl restart nginx"
fi
echo "  Check Odoo status:   sudo systemctl status odoo"
if [ "$WORKER_MODE" = "yes" ]; then
    echo "  Check Nginx status:  sudo systemctl status nginx"
fi
echo ""
echo "Database Credentials:"
echo "  User:     $DB_USER"
echo "  Password: [provided during setup]"
echo ""
echo "==========================================="
