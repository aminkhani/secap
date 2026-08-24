#!/usr/bin/env bash
set -euo pipefail

echo "================================================="
echo " SECAP Setup Wizard"
echo "================================================="
echo

# ── 1. Pick stage ────────────────────────────────────────────────
echo "Select environment:"
echo "  1) dev"
echo "  2) prod"
read -rp "Choice [1/2]: " STAGE_CHOICE

case "$STAGE_CHOICE" in
    1)
        STAGE="dev"
        ENV_FILE=".env.dev"
        COMPOSE_FILE="docker-compose.dev.yml"
        SETTINGS_MODULE="secapserver.settings.dev"
        ;;
    2)
        STAGE="prod"
        ENV_FILE=".env.prod"
        COMPOSE_FILE="docker-compose.prod.yml"
        SETTINGS_MODULE="secapserver.settings.prod"
        ;;
    *)
        echo "ERROR: Invalid environment choice."
        exit 1
        ;;
esac

if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: $ENV_FILE not found in $(pwd)."
    echo "Run this script from the project root."
    exit 1
fi

if [ ! -f "$COMPOSE_FILE" ]; then
    echo "ERROR: $COMPOSE_FILE not found in $(pwd)."
    echo "Run this script from the project root."
    exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: Docker is not installed."
    exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
    echo "ERROR: Docker Compose is not available."
    exit 1
fi

echo
echo "Stage selected: $STAGE"

# ── 2. Pick installation mode ────────────────────────────────────
# ── 2. Pick installation mode ────────────────────────────────────
echo
echo "Select operation:"
echo "  1) New installation"
echo "     Deletes ALL Docker data and rebuilds from scratch."
echo "  2) Existing installation — update server IP/domain"
echo "     Preserves database, Redis, media, and other volumes."
echo "  3) Existing installation — update code (git pull + rebuild + restart)"
echo "     Preserves volumes; recreates containers from rebuilt images."
read -rp "Choice [1/2/3]: " INSTALL_CHOICE

case "$INSTALL_CHOICE" in
    1) INSTALL_MODE="new" ;;
    2) INSTALL_MODE="update_host" ;;
    3) INSTALL_MODE="update_code" ;;
    *) echo "ERROR: Invalid operation choice."; exit 1 ;;
esac

# ── 3. Helpers ───────────────────────────────────────────────────
get_env_value() {
    local key="$1"
    local default_value="$2"
    local value

    value="$(
        grep -E "^${key}=" "$ENV_FILE" |
            tail -n 1 |
            cut -d '=' -f 2- || true
    )"

    if [ -z "$value" ]; then
        printf '%s\n' "$default_value"
    else
        printf '%s\n' "$value"
    fi
}

set_env_value() {
    local key="$1"
    local value="$2"

    if grep -qE "^${key}=" "$ENV_FILE"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
    else
        printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
    fi
}

generate_secret_key() {
    if ! command -v openssl >/dev/null 2>&1; then
        echo "ERROR: openssl is required to generate SECRET_KEY."
        exit 1
    fi

    openssl rand -hex 50
}

validate_server_host() {
    local server_host="$1"

    if [ -z "$server_host" ]; then
        echo "ERROR: Server IP/domain cannot be empty."
        exit 1
    fi

    if [[ ! "$server_host" =~ ^[A-Za-z0-9.:_-]+$ ]]; then
        echo "ERROR: Invalid server IP/domain: $server_host"
        echo "Do not include http://, https://, a path, or a port."
        exit 1
    fi
}

format_url_host() {
    local server_host="$1"

    if [[ "$server_host" == *:* ]]; then
        printf '[%s]\n' "$server_host"
    else
        printf '%s\n' "$server_host"
    fi
}

generate_tls_certificate() {
    local server_host="$1"
    local cert_dir="nginx/certs"
    local temp_dir
    local san_type

    if ! command -v openssl >/dev/null 2>&1; then
        echo "ERROR: openssl is required to generate TLS certificates."
        exit 1
    fi

    if [[ "$server_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
       [[ "$server_host" == *:* ]]; then
        san_type="IP"
    else
        san_type="DNS"
    fi

    mkdir -p "$cert_dir"
    temp_dir="$(mktemp -d "$cert_dir/.tls.XXXXXX")"

    cleanup_tls_temp() {
        rm -rf "$temp_dir"
    }
    trap cleanup_tls_temp RETURN

    echo
    echo "================================================="
    echo " Generating TLS certificate"
    echo "================================================="
    echo "  Subject: CN=${server_host}"
    echo "  SAN:     ${san_type}:${server_host}"

    openssl req \
        -x509 \
        -newkey rsa:4096 \
        -sha256 \
        -nodes \
        -days 365 \
        -keyout "$temp_dir/privkey.pem" \
        -out "$temp_dir/fullchain.pem" \
        -subj "/CN=${server_host}" \
        -addext "subjectAltName=${san_type}:${server_host}" \
        -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
        -addext "extendedKeyUsage=serverAuth"

    chmod 600 "$temp_dir/privkey.pem"
    chmod 644 "$temp_dir/fullchain.pem"

    rm -f "$cert_dir/fullchain.pem" "$cert_dir/privkey.pem"
    mv "$temp_dir/fullchain.pem" "$cert_dir/fullchain.pem"
    mv "$temp_dir/privkey.pem" "$cert_dir/privkey.pem"

    echo "TLS certificate generated successfully:"
    echo "  $cert_dir/fullchain.pem"
    echo "  $cert_dir/privkey.pem"
}

check_port_available() {
    local port="$1"

    if ! [[ "$port" =~ ^[0-9]+$ ]] ||
       ((port < 1 || port > 65535)); then
        echo "ERROR: Invalid port: $port"
        exit 1
    fi

    if ! command -v ss >/dev/null 2>&1; then
        echo "ERROR: The 'ss' command is required to check ports."
        echo "Install it with: sudo apt install iproute2"
        exit 1
    fi

    if ss -H -ltn "sport = :${port}" | grep -q .; then
        echo "ERROR: TCP port ${port} is already in use."
        echo
        ss -ltnp "sport = :${port}" || true
        echo
        echo "Docker containers publishing this port:"
        docker ps \
            --filter "publish=${port}" \
            --format '  {{.Names}}: {{.Ports}}' || true
        exit 1
    fi

    echo "TCP port ${port} is available."
}

delete_all_docker_data() {
    echo
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo " DESTRUCTIVE DOCKER RESET"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo
    echo "This will permanently delete:"
    echo "  - All Docker containers"
    echo "  - All Docker images"
    echo "  - All Docker volumes"
    echo "  - All unused Docker networks"
    echo "  - All Docker build cache"
    echo
    echo "This affects every Docker project on this server."
    echo
    read -rp "Type DELETE ALL DOCKER DATA to continue: " DELETE_CONFIRMATION

    if [ "$DELETE_CONFIRMATION" != "DELETE ALL DOCKER DATA" ]; then
        echo "ERROR: Confirmation did not match. Nothing was deleted."
        exit 1
    fi

    echo
    echo "Removing all Docker containers..."
    docker ps -aq | xargs -r docker rm -f

    echo "Removing images, volumes, networks, and build cache..."
    docker system prune -a --volumes -f

    echo "Docker cleanup completed."
}

show_urls() {
    echo
    echo "================================================="
    echo " Access URLs"
    echo "================================================="
    echo

    if [ "$STAGE" = "prod" ]; then
        local base_url="https://${URL_HOST}:${HTTPS_PORT}"

        echo "Production exposes only HTTPS port ${HTTPS_PORT}."
        echo
        echo "Django project:"
        echo "  ${base_url}/"
        echo
        echo "Flower:"
        echo "  ${base_url}/flower/"
        echo
        echo "Docs:"
        echo "  ${base_url}/docs/"
        echo
        echo "SCAP repo:"
        echo "  ${base_url}/repo/"
        echo
        echo "Portainer:"
        echo "  ${base_url}/portainer/"
    else
        echo "Django project:"
        echo "  http://${URL_HOST}:${WEB_PORT}/"
        echo
        echo "Flower:"
        echo "  http://${URL_HOST}:${FLOWER_PORT}/"
        echo
        echo "Docs:"
        echo "  http://${URL_HOST}:${DOCS_PORT}/"
        echo
        echo "SCAP repo:"
        echo "  http://${URL_HOST}:${SCAP_REPO_PORT}/"
        echo
        echo "Grafana:"
        echo "  http://${URL_HOST}:${GRAFANA_PORT}/"
        echo
        echo "Portainer:"
        echo "  http://${URL_HOST}:${PORTAINER_PORT}/"
    fi

    echo
    echo "================================================="
    echo " Settings module in use: $SETTINGS_MODULE"
    echo "================================================="
    echo
}

# ── 4. Read ports ────────────────────────────────────────────────
WEB_PORT="$(get_env_value "WEB_PORT" "8000")"
FLOWER_PORT="$(get_env_value "FLOWER_PORT" "5555")"
DOCS_PORT="$(get_env_value "DOCS_PORT" "8888")"
SCAP_REPO_PORT="$(get_env_value "SCAP_REPO_PORT" "8080")"
GRAFANA_PORT="$(get_env_value "GRAFANA_PORT" "3000")"
PORTAINER_PORT="$(get_env_value "PORTAINER_PORT" "9443")"
HTTPS_PORT="8443"

# ── 5. Ask for server address ────────────────────────────────────
if [ "$INSTALL_MODE" != "update_code" ]; then
    CURRENT_SERVER_HOST="$(get_env_value "ALLOWED_HOSTS" "")"

    echo
    if [ -n "$CURRENT_SERVER_HOST" ]; then
        echo "Current server IP/domain: $CURRENT_SERVER_HOST"
    fi

    read -rp "Enter new server IP or domain, example 10.16.13.251: " SERVER_HOST
    validate_server_host "$SERVER_HOST"

    URL_HOST="$(format_url_host "$SERVER_HOST")"

    if [ "$STAGE" = "prod" ]; then
        CSRF_TRUSTED_ORIGINS_VALUE="https://${URL_HOST}:${HTTPS_PORT}"
        DOCS_URL="https://${URL_HOST}:${HTTPS_PORT}"
    else
        CSRF_TRUSTED_ORIGINS_VALUE="http://${URL_HOST}:${WEB_PORT}"
        DOCS_URL="http://${URL_HOST}:${WEB_PORT}"
    fi

    ALLOWED_HOSTS_VALUE="$SERVER_HOST"
else
    # For summary/urls, derive host from current env if needed
    SERVER_HOST="$(get_env_value "ALLOWED_HOSTS" "localhost")"
    URL_HOST="$(format_url_host "$SERVER_HOST")"
fi

# ── 6. Confirm operation ─────────────────────────────────────────
echo
echo "This setup will use:"
echo "  Stage:              $STAGE"
echo "  Operation:          $INSTALL_MODE"
echo "  Server host:        $SERVER_HOST"

if [ "$STAGE" = "prod" ]; then
    echo "  Public HTTPS port:  $HTTPS_PORT"
    echo "  Other services:     Available through HTTPS paths"
else
    echo "  Web port:           $WEB_PORT"
    echo "  Flower port:        $FLOWER_PORT"
    echo "  Docs port:          $DOCS_PORT"
    echo "  SCAP repo port:     $SCAP_REPO_PORT"
    echo "  Grafana port:       $GRAFANA_PORT"
    echo "  Portainer port:     $PORTAINER_PORT"
fi

if [ "$INSTALL_MODE" = "new" ]; then
    echo "  SECRET_KEY:         A new key will be generated"
    echo "  Docker data:        ALL Docker data will be deleted"
else
    echo "  SECRET_KEY:         Preserved"
    echo "  Persistent data:    Preserved"
fi

echo
read -rp "Continue? [y/N]: " CONFIRM

case "$CONFIRM" in
    y | Y | yes | YES)
        ;;
    *)
        echo "Cancelled."
        exit 0
        ;;
esac

# ── 7. Update environment and TLS ────────────────────────────────
if [ "$INSTALL_MODE" != "update_code" ]; then
    set_env_value "ALLOWED_HOSTS" "$ALLOWED_HOSTS_VALUE"
    set_env_value "CSRF_TRUSTED_ORIGINS" "$CSRF_TRUSTED_ORIGINS_VALUE"
    set_env_value "DOCS_URL" "$DOCS_URL"


    echo
    echo "Environment updated:"
    echo "  ALLOWED_HOSTS=${ALLOWED_HOSTS_VALUE}"
    echo "  CSRF_TRUSTED_ORIGINS=${CSRF_TRUSTED_ORIGINS_VALUE}"

    if [ "$INSTALL_MODE" = "new" ]; then
        NEW_SECRET_KEY="$(generate_secret_key)"
        set_env_value "SECRET_KEY" "$NEW_SECRET_KEY"
        unset NEW_SECRET_KEY
        echo "  SECRET_KEY generated successfully."
    else
        echo "  SECRET_KEY preserved."
    fi

    if [ "$STAGE" = "prod" ]; then
        generate_tls_certificate "$SERVER_HOST"
    fi
fi

# ── 8a. Existing installation code update ────────────────────────
if [ "$INSTALL_MODE" = "update_code" ]; then
    echo
    echo "================================================="
    echo " Updating code (rebuild + restart)"
    echo "================================================="

    echo "Rebuilding application images..."
    docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" build

    echo "Restarting application services..."
    # We recreate all services that use the custom code/images
    if [ "$STAGE" = "prod" ]; then
        docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d \
            --force-recreate web celery_worker celery_beat flower nginx docs repo
    else
        docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d \
            --force-recreate web celery_worker celery_beat flower docs
    fi

    show_urls
    echo "Code update completed successfully."
    exit 0
fi

# ── 8. Existing installation update ──────────────────────────────
if [ "$INSTALL_MODE" = "update_host" ]; then
    echo
    echo "================================================="
    echo " Updating existing installation"
    echo "================================================="
    echo "Persistent volumes and application data will be preserved."

    if [ "$STAGE" = "prod" ]; then
        docker compose \
            --env-file "$ENV_FILE" \
            -f "$COMPOSE_FILE" \
            up -d --no-deps --force-recreate web nginx
    else
        docker compose \
            --env-file "$ENV_FILE" \
            -f "$COMPOSE_FILE" \
            up -d --no-deps --force-recreate web
    fi

    show_urls
    echo "Update completed without deleting persistent data."
    exit 0
fi

# ── 9. New installation cleanup ──────────────────────────────────
delete_all_docker_data

# ── 10. Check public ports ───────────────────────────────────────
echo
echo "================================================="
echo " Checking required public ports"
echo "================================================="

if [ "$STAGE" = "prod" ]; then
    check_port_available "$HTTPS_PORT"
else
    check_port_available "$WEB_PORT"
    check_port_available "$FLOWER_PORT"
    check_port_available "$DOCS_PORT"
    check_port_available "$SCAP_REPO_PORT"
    check_port_available "$GRAFANA_PORT"
    check_port_available "$PORTAINER_PORT"
fi

# ── 11. Validate Compose ─────────────────────────────────────────
echo
echo "================================================="
echo " Validating Docker Compose"
echo "================================================="

docker compose \
    --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" \
    config --quiet

# ── 12. Build ────────────────────────────────────────────────────
echo
echo "================================================="
echo " Building images ($STAGE)"
echo "================================================="

docker compose \
    --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" \
    build

# ── 13. Start ────────────────────────────────────────────────────
echo
echo "================================================="
echo " Starting stack ($STAGE)"
echo "================================================="

docker compose \
    --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" \
    up -d

# ── 14. Summary ──────────────────────────────────────────────────
show_urls
echo "New installation completed."
