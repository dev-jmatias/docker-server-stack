# Docker Server Stack

Automated installer for a CQDX Brasil Ubuntu VPS.

Installs and configures:

- Docker Engine
- Docker Compose Plugin
- Traefik reverse proxy
- Automatic HTTPS with Let's Encrypt
- Protected Traefik dashboard
- Portainer CE LTS
- Shared Docker `proxy` network

## Domains

- Traefik: `traefik.cqdxbrasil.com`
- Portainer: `portainer.cqdxbrasil.com`

## Requirements

- Ubuntu 22.04 or 24.04
- Root/sudo access
- DNS records for both domains pointing to the server public IP
- TCP ports 80 and 443 reachable from the Internet

## Installation

```bash
git clone https://github.com/dev-jmatias/docker-server-stack.git
cd docker-server-stack
sudo bash install-stack.sh
```

For a private repository, authenticate Git on the server before cloning, or use an authenticated GitHub method.

## After installation

Traefik dashboard:

`https://traefik.cqdxbrasil.com/dashboard/`

Portainer:

`https://portainer.cqdxbrasil.com`

The installer generates a random password for the Traefik dashboard. It prints the credentials at the end and stores them root-only in:

`/opt/apps/traefik/dashboard-credentials.txt`

## Notes

The installer is intended to be safe to re-run where possible. Existing services occupying TCP ports 80 or 443 can prevent installation.
