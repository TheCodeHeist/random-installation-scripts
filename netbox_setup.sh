#!/usr/bin/env bash
# /workspaces/random-installation-scripts/netbox_setup.sh
# Install NetBox on Debian/Ubuntu (tested on Ubuntu 24.04)
# Minimal, idempotent-ish installer with configurable options.
#
# Usage:
#   sudo ./netbox_setup.sh
# or set environment vars before running to customize:
#   NETBOX_VERSION="v4.4.1" DB_PASSWORD="secret" ./netbox_setup.sh

set -euo pipefail
IFS=$'\n\t'

# -------------------------
# Configuration (override via env)
# -------------------------
NETBOX_VERSION="${NETBOX_VERSION:-latest}"      # git tag or "latest" for default branch
INSTALL_DIR="${INSTALL_DIR:-/opt/netbox}"      # where netbox will be cloned
NETBOX_USER="${NETBOX_USER:-netbox}"           # system user to run NetBox
NETBOX_GROUP="${NETBOX_GROUP:-netbox}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
VENV_DIR="${VENV_DIR:-$INSTALL_DIR/venv}"~
DB_NAME="${DB_NAME:-netbox}"
DB_USER="${DB_USER:-netbox}"
DB_PASSWORD="${DB_PASSWORD:-netboxpass}"       # change in production
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-postgres}" # (for local postgres superuser if needed)
REDIS_CONF="${REDIS_CONF:-/etc/redis/redis.conf}"
DOMAIN="${DOMAIN:-localhost}"                  # used for ALLOWED_HOSTS
ALLOWED_HOSTS="${ALLOWED_HOSTS:-$DOMAIN}"      # comma or space separated
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-adminpass}"  # change in production
GUNICORN_SOCKET="${GUNICORN_SOCKET:-/run/netbox.sock}"
GUNICORN_WORKERS="${GUNICORN_WORKERS:-3}"
DEBIAN_FRONTEND="noninteractive"

# Determine whether we need sudo
if [ "$(id -u)" -ne 0 ]; then
  SUDO="sudo -E"
else
  SUDO=""
fi

# Helper: log
log() { echo "==> $*"; }

# -------------------------
# Basic tools & packages
# -------------------------
install_packages() {
  log "Updating apt and installing system packages..."
  $SUDO apt-get update -y
  $SUDO apt-get install -y git curl wget gnupg lsb-release ca-certificates \
    $PYTHON_BIN $PYTHON_BIN-venv $PYTHON_BIN-dev build-essential libpq-dev \
    postgresql postgresql-contrib redis-server nginx gcc
}

# -------------------------
# PostgreSQL setup
# -------------------------
setup_postgres() {
  log "Configuring PostgreSQL database and user..."
  # Ensure postgres service running
  $SUDO systemctl enable --now postgresql

  # Create DB user and DB if not exists
  sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1 || \
    sudo -u postgres psql -c "CREATE ROLE $DB_USER WITH LOGIN PASSWORD '$DB_PASSWORD';"
  sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1 || \
    sudo -u postgres psql -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;"
}

# -------------------------
# System user
# -------------------------
create_system_user() {
  if ! id "$NETBOX_USER" >/dev/null 2>&1; then
    log "Creating system user '$NETBOX_USER'..."
    $SUDO useradd --system --home $INSTALL_DIR --shell /usr/sbin/nologin --create-home $NETBOX_USER || true
  else
    log "System user $NETBOX_USER exists."
  fi
}

# -------------------------
# Clone NetBox
# -------------------------
clone_netbox() {
  if [ -d "$INSTALL_DIR/.git" ]; then
    log "NetBox already cloned. Pulling latest..."
    $SUDO git -C "$INSTALL_DIR" fetch --all --tags
    if [ "$NETBOX_VERSION" = "latest" ]; then
      $SUDO git -C "$INSTALL_DIR" checkout main || $SUDO git -C "$INSTALL_DIR" checkout master || true
      $SUDO git -C "$INSTALL_DIR" pull --ff-only || true
    else
      $SUDO git -C "$INSTALL_DIR" checkout "$NETBOX_VERSION" || $SUDO git -C "$INSTALL_DIR" fetch --tags && $SUDO git -C "$INSTALL_DIR" checkout "$NETBOX_VERSION"
    fi
  else
    log "Cloning NetBox into $INSTALL_DIR..."
    $SUDO git clone https://github.com/netbox-community/netbox.git "$INSTALL_DIR"
    if [ "$NETBOX_VERSION" != "latest" ]; then
      $SUDO git -C "$INSTALL_DIR" checkout "$NETBOX_VERSION"
    fi
  fi
  $SUDO chown -R "$NETBOX_USER:$NETBOX_GROUP" "$INSTALL_DIR"
}

# -------------------------
# Python venv & pip deps
# -------------------------
setup_virtualenv() {
  log "Creating python virtualenv and installing python requirements..."
  if [ ! -d "$VENV_DIR" ]; then
    $SUDO -u "$NETBOX_USER" $PYTHON_BIN -m venv "$VENV_DIR"
  fi
  PIP="$VENV_DIR/bin/pip"
  PY="$VENV_DIR/bin/python"
  $SUDO -u "$NETBOX_USER" "$PIP" install --upgrade pip wheel
  # Install NetBox requirements
  if [ -f "$INSTALL_DIR/requirements.txt" ]; then
    $SUDO -u "$NETBOX_USER" "$PIP" install -r "$INSTALL_DIR/requirements.txt"
  fi
  # Install gunicorn (if not in requirements)
  $SUDO -u "$NETBOX_USER" "$PIP" install "gunicorn"
}

# -------------------------
# Configure NetBox (configuration.py)
# -------------------------
configure_netbox() {
  log "Configuring NetBox settings..."
  local cfgdir="$INSTALL_DIR/netbox/netbox"
  local example="$cfgdir/configuration.example.py"
  local cfg="$cfgdir/configuration.py"
  if [ ! -f "$cfg" ]; then
    $SUDO cp "$example" "$cfg"
  fi
  # Generate SECRET_KEY
  SECRET_KEY=$($SUDO openssl rand -hex 32)
  # Write minimal database and allowed hosts settings appended to configuration.py
  $SUDO bash -c "cat >> '$cfg' <<EOF

# --- automated additions ---
SECRET_KEY = '$SECRET_KEY'
ALLOWED_HOSTS = ['${ALLOWED_HOSTS//,/','}']

DATABASE = {
    'NAME': '$DB_NAME',
    'USER': '$DB_USER',
    'PASSWORD': '$DB_PASSWORD',
    'HOST': 'localhost',
    'PORT': '',
}

REDIS = {
    'caches': {
        'default': {
            'HOST': 'localhost',
            'PORT': 6379,
            'PASSWORD': '',
            'DATABASE': 0,
            'SSL': False,
        }
    }
}
# --- end automated additions ---
EOF"
  $SUDO chown "$NETBOX_USER:$NETBOX_GROUP" "$cfg"
}

# -------------------------
# Migrate, collectstatic, create superuser
# -------------------------
django_manage() {
  local manage="$VENV_DIR/bin/python $INSTALL_DIR/netbox/manage.py"
  log "Running Django migrations..."
  $SUDO -u "$NETBOX_USER" bash -c "cd $INSTALL_DIR && $VENV_DIR/bin/python netbox/manage.py migrate --noinput"
  log "Collecting static files..."
  $SUDO -u "$NETBOX_USER" bash -c "cd $INSTALL_DIR && $VENV_DIR/bin/python netbox/manage.py collectstatic --no-input"
  log "Creating admin user (if not exists)..."
  # Create superuser via Django shell
  $SUDO -u "$NETBOX_USER" bash -c "cd $INSTALL_DIR && $VENV_DIR/bin/python netbox/manage.py shell <<PY
from django.contrib.auth import get_user_model
User = get_user_model()
if not User.objects.filter(username='$ADMIN_USER').exists():
    User.objects.create_superuser('$ADMIN_USER', '$ADMIN_EMAIL', '$ADMIN_PASSWORD')
    print('created')
else:
    print('exists')
PY"
}

# -------------------------
# Systemd service for gunicorn
# -------------------------
install_systemd_service() {
  log "Installing systemd service for NetBox (gunicorn)..."
  local service="/etc/systemd/system/netbox.service"
  $SUDO bash -c "cat > '$service' <<EOF
[Unit]
Description=NetBox WSGI Service (gunicorn)
After=network.target

[Service]
User=$NETBOX_USER
Group=$NETBOX_GROUP
WorkingDirectory=$INSTALL_DIR
ExecStart=$VENV_DIR/bin/gunicorn --workers $GUNICORN_WORKERS --bind unix:$GUNICORN_SOCKET netbox.wsgi
Restart=always

[Install]
WantedBy=multi-user.target
EOF"
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable --now netbox.service
}

# -------------------------
# Nginx configuration
# -------------------------
install_nginx() {
  log "Configuring nginx..."
  local site="/etc/nginx/sites-available/netbox"
  $SUDO bash -c "cat > '$site' <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    client_max_body_size 25m;
    access_log /var/log/nginx/netbox-access.log;
    error_log /var/log/nginx/netbox-error.log;

    location /static/ {
        alias $INSTALL_DIR/static/;
    }

    location / {
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_pass http://unix:$GUNICORN_SOCKET;
    }
}
EOF"
  $SUDO ln -sf "$site" /etc/nginx/sites-enabled/netbox
  $SUDO nginx -t
  $SUDO systemctl enable --now nginx
}

# -------------------------
# Permissions & ownership
# -------------------------
fix_permissions() {
  log "Fixing permissions for $INSTALL_DIR..."
  $SUDO chown -R "$NETBOX_USER:$NETBOX_GROUP" "$INSTALL_DIR"
  mkdir -p "$(dirname "$GUNICORN_SOCKET")"
  $SUDO chown "$NETBOX_USER:$NETBOX_GROUP" "$(dirname "$GUNICORN_SOCKET")"
}

# -------------------------
# Main execution
# -------------------------
main() {
  log "Starting NetBox installer"
  install_packages
  setup_postgres
  create_system_user
  clone_netbox
  setup_virtualenv
  configure_netbox
  fix_permissions
  django_manage
  install_systemd_service
  install_nginx

  log "NetBox should be available at http://$DOMAIN/ (may take a few seconds to be ready)"
  log "Admin user: $ADMIN_USER  Email: $ADMIN_EMAIL"
  log "If you changed passwords above, make sure to store them securely."
}

main "$@"