#!/usr/bin/env bash
set -Eeuo pipefail

# CQDX Brasil - Docker + Traefik + Portainer installer
# Target: Ubuntu 22.04 / 24.04
# Run: sudo bash install-stack.sh

TRAEFIK_DOMAIN="traefik.cqdxbrasil.com"
PORTAINER_DOMAIN="portainer.cqdxbrasil.com"
ACME_EMAIL="dev.jmatias@gmail.com"
PROXY_NETWORK="proxy"
BASE_DIR="/opt/apps"
TRAEFIK_DIR="${BASE_DIR}/traefik"
PORTAINER_DIR="${BASE_DIR}/portainer"

log(){ printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
die(){ printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0"
source /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "This installer supports Ubuntu only."

REAL_USER="${SUDO_USER:-${USER:-root}}"
export DEBIAN_FRONTEND=noninteractive

log "Installing prerequisites"
apt-get update
apt-get install -y ca-certificates curl gnupg openssl apache2-utils iproute2

if ! command -v docker >/dev/null 2>&1; then
  log "Installing Docker Engine"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
elif ! docker compose version >/dev/null 2>&1; then
  apt-get update
  apt-get install -y docker-compose-plugin
fi

systemctl enable --now docker
if id "$REAL_USER" >/dev/null 2>&1 && [[ "$REAL_USER" != root ]]; then
  usermod -aG docker "$REAL_USER"
fi

log "Checking ports 80 and 443"
for port in 80 443; do
  if ss -ltnH "( sport = :$port )" 2>/dev/null | grep -q .; then
    docker ps --format '{{.Names}}' | grep -qx traefik || die "TCP port $port is already in use."
  fi
done

log "Creating Docker network and directories"
docker network inspect "$PROXY_NETWORK" >/dev/null 2>&1 || docker network create "$PROXY_NETWORK"
mkdir -p "$TRAEFIK_DIR/letsencrypt" "$PORTAINER_DIR"
touch "$TRAEFIK_DIR/letsencrypt/acme.json"
chmod 600 "$TRAEFIK_DIR/letsencrypt/acme.json"

CRED_FILE="$TRAEFIK_DIR/dashboard-credentials.txt"
if [[ -s "$CRED_FILE" ]]; then
  TRAEFIK_USER="$(sed -n 's/^username=//p' "$CRED_FILE")"
  TRAEFIK_PASSWORD="$(sed -n 's/^password=//p' "$CRED_FILE")"
else
  TRAEFIK_USER="admin"
  TRAEFIK_PASSWORD="$(openssl rand -hex 16)"
  umask 077
  printf 'username=%s\npassword=%s\n' "$TRAEFIK_USER" "$TRAEFIK_PASSWORD" > "$CRED_FILE"
fi

# Generate bcrypt BasicAuth and escape $ for Docker Compose.
BASIC_AUTH="$(htpasswd -nbB "$TRAEFIK_USER" "$TRAEFIK_PASSWORD" | sed 's/\$/\$\$/g')"

log "Writing Traefik configuration"
cat >"$TRAEFIK_DIR/compose.yaml" <<EOF
services:
  traefik:
    image: traefik:v3.7
    container_name: traefik
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    networks:
      - ${PROXY_NETWORK}
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./letsencrypt:/letsencrypt
    command:
      - --api.dashboard=true
      - --api.insecure=false
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --providers.docker.network=${PROXY_NETWORK}
      - --entrypoints.web.address=:80
      - --entrypoints.web.http.redirections.entrypoint.to=websecure
      - --entrypoints.web.http.redirections.entrypoint.scheme=https
      - --entrypoints.websecure.address=:443
      - --certificatesresolvers.letsencrypt.acme.email=${ACME_EMAIL}
      - --certificatesresolvers.letsencrypt.acme.storage=/letsencrypt/acme.json
      - --certificatesresolvers.letsencrypt.acme.httpchallenge=true
      - --certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=web
      - --log.level=INFO
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.traefik.rule=Host(\`${TRAEFIK_DOMAIN}\`)"
      - "traefik.http.routers.traefik.entrypoints=websecure"
      - "traefik.http.routers.traefik.tls=true"
      - "traefik.http.routers.traefik.tls.certresolver=letsencrypt"
      - "traefik.http.routers.traefik.service=api@internal"
      - "traefik.http.routers.traefik.middlewares=traefik-auth"
      - "traefik.http.middlewares.traefik-auth.basicauth.users=${BASIC_AUTH}"

networks:
  ${PROXY_NETWORK}:
    external: true
EOF

log "Writing Portainer configuration"
cat >"$PORTAINER_DIR/compose.yaml" <<EOF
services:
  portainer:
    image: portainer/portainer-ce:lts
    container_name: portainer
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    networks:
      - ${PROXY_NETWORK}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.portainer.rule=Host(\`${PORTAINER_DOMAIN}\`)"
      - "traefik.http.routers.portainer.entrypoints=websecure"
      - "traefik.http.routers.portainer.tls=true"
      - "traefik.http.routers.portainer.tls.certresolver=letsencrypt"
      - "traefik.http.routers.portainer.service=portainer"
      - "traefik.http.services.portainer.loadbalancer.server.port=9000"

volumes:
  portainer_data:
    name: portainer_portainer_data

networks:
  ${PROXY_NETWORK}:
    external: true
EOF

# Validate interpolation before touching containers.
log "Validating Docker Compose files"
docker compose -f "$TRAEFIK_DIR/compose.yaml" config >/dev/null
docker compose -f "$PORTAINER_DIR/compose.yaml" config >/dev/null

log "Starting Traefik"
docker compose -f "$TRAEFIK_DIR/compose.yaml" pull
docker compose -f "$TRAEFIK_DIR/compose.yaml" up -d --force-recreate

log "Starting Portainer"
docker compose -f "$PORTAINER_DIR/compose.yaml" pull
docker compose -f "$PORTAINER_DIR/compose.yaml" up -d --force-recreate

sleep 3

log "Container status"
docker ps --filter name=traefik --filter name=portainer --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'

cat <<EOF

Installation complete.

Traefik:  https://${TRAEFIK_DOMAIN}/dashboard/
Portainer: https://${PORTAINER_DOMAIN}

Traefik dashboard credentials:
  Username: ${TRAEFIK_USER}
  Password: ${TRAEFIK_PASSWORD}

Credentials are stored at:
  ${CRED_FILE}

IMPORTANT:
- ${TRAEFIK_DOMAIN} and ${PORTAINER_DOMAIN} must point to this server's public IP.
- TCP ports 80 and 443 must be reachable from the Internet.
- If ${REAL_USER} was added to the docker group, log out and back in before using Docker without sudo.
EOF
