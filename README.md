# Airlink Panel + Node (Daemon)

Airlink game server management panel + daemon, packaged with a one-command manager.

## One-command menu installer

Run this on a fresh Ubuntu/Debian server (as root or sudo):

```bash
bash <(curl -s https://raw.githubusercontent.com/kiragamingofficial95-cmd/airlink/main/install.sh)
```

You'll get a menu:
- **1** — Install Panel (web panel + PostgreSQL + Redis, systemd service `airlink-panel`)
- **2** — Install Node (daemon, Docker, systemd service `airlink-daemon`)
- **0** — Exit

### Direct / non-interactive

```bash
# Panel only
bash <(curl -s ...) --panel-only

# Node/daemon only
bash <(curl -s ...) --daemon-only
```

## Repo layout

```
├── install.sh            # manager / one-command installer
├── Dockerfile            # single-container (panel + daemon + PG + Redis)
├── docker-compose.yml    # compose wrapper for the above
├── entrypoint.sh         # container init
├── compose.env           # example container env (KEYS) — copy to .env
├── panel-main/           # Airlink panel source
└── daemon-main/
    └── daemon-main/      # Airlink daemon source
```

## Docker container option

```bash
docker compose --env-file compose.env up -d --build
```

> **Note:** the daemon inside the container manages game-server containers through the mounted Docker socket (`/var/run/docker.sock`).