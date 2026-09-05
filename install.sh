#!/usr/bin/env bash
############################################################################
# Airlink Manager - one-command installer for Panel + Node (daemon)
#
# Usage:
#   bash <(curl -s https://raw.githubusercontent.com/kiragamingofficial95-cmd/airlink/main/install.sh)
#
# Menu:
#   1) Install Panel   (Airlink web panel + PostgreSQL + Redis)
#   2) Install Node    (Airlink daemon)
#   0) Exit
############################################################################

set -uo pipefail

GIT_REPO="https://github.com/kiragamingofficial95-cmd/airlink.git"
GIT_BRANCH="main"
LOG="/tmp/airlink-manager.log"
VERSION="1.0.0"

C_GREEN=$'\033[92m'; C_RED=$'\033[91m'; C_CYAN=$'\033[96m'
C_YELLOW=$'\033[93m'; C_GRAY=$'\033[90m'; RESET=$'\033[0m'; BOLD=$'\033[1m'

PANEL_DIR="/var/www/panel"
DAEMON_DIR="/etc/daemon"
PANEL_PORT="3000"
DAEMON_PORT="3002"
SFTP_BASE="/srv/airlink"

log() { echo "[$(date '+%H:%M:%S')] $*" >> "$LOG"; }
info() { echo "  ${C_YELLOW}[info]${RESET} $*"; }
ok()   { echo "  ${C_GREEN}[ok]${RESET} $*"; }
fail() { echo "  ${C_RED}[fail]${RESET} $*"; }

die() { echo; echo "  ${BOLD}${C_RED}error:${RESET} $*"; echo; exit 1; }

# ----------------------------------------------------------------------------
# OS / package manager detection
# ----------------------------------------------------------------------------
OS="" PKG=""
detect_os() {
    [[ -f /etc/os-release ]] || die "Cannot detect OS - /etc/os-release missing"
    OS=$(grep '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
    case "$OS" in
        ubuntu|debian|linuxmint|pop|raspbian) PKG="apt" ;;
        fedora|centos|rhel|rocky|almalinux|ol) PKG="dnf" ;;
        arch|manjaro|endeavouros) PKG="pacman" ;;
        alpine) PKG="apk" ;;
        *) die "Unsupported OS: $OS" ;;
    esac
    ok "Detected OS: $OS (pkg: $PKG)"
}

pkg_install() {
    case "$PKG" in
        apt) DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" ;;
        dnf) dnf install -y -q "$@" ;;
        pacman) pacman -Sy --noconfirm --needed "$@" ;;
        apk) apk add --no-cache -q "$@" ;;
    esac
}

ensure_base_deps() {
    local deps=(curl wget git openssl unzip tar)
    local missing=()
    for d in "${deps[@]}"; do
        command -v "$d" &>/dev/null || missing+=("$d")
    done
    [[ ${#missing[@]} -gt 0 ]] && pkg_install "${missing[@]}"
}

# ----------------------------------------------------------------------------
# Node.js + pnpm (panel)
# ----------------------------------------------------------------------------
ensure_node() {
    if command -v node &>/dev/null; then
        local major; major=$(node -e "console.log(process.versions.node.split('.')[0])")
        if [[ "$major" -ge 22 ]]; then ok "Node.js $(node -v)"; return; fi
        info "Node $major too old - upgrading to 22"
    fi
    case "$PKG" in
        apt)
            curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs
            ;;
        dnf)
            curl -fsSL https://rpm.nodesource.com/setup_22.x | bash - >/dev/null 2>&1
            dnf install -y -q nodejs
            ;;
        pacman) pkg_install nodejs npm ;;
        apk) pkg_install nodejs npm ;;
    esac
    command -v node &>/dev/null || die "Node.js install failed"
    ok "Node.js $(node -v)"
    command -v pnpm &>/dev/null || npm install -g pnpm >/dev/null 2>&1
    command -v pnpm &>/dev/null || die "pnpm install failed"
    ok "pnpm $(pnpm -v)"
}

# ----------------------------------------------------------------------------
# Docker (needed by both - the daemon manages containers)
# ----------------------------------------------------------------------------
ensure_docker() {
    if command -v docker &>/dev/null; then ok "Docker already installed"; return; fi
    info "Installing Docker..."
    case "$PKG" in
        apt|dnf) curl -fsSL https://get.docker.com | sh >/dev/null 2>&1 ;;
        pacman) pkg_install docker docker-compose ;;
        apk) pkg_install docker docker-compose; rc-update add docker boot >/dev/null 2>&1 || true ;;
    esac
    command -v docker &>/dev/null || die "Docker install failed"
    if command -v systemctl &>/dev/null; then
        systemctl enable --now docker >/dev/null 2>&1 || true
    fi
    ok "Docker $(docker --version | awk '{print $3}' | tr -d '.,') installed"
}

# ----------------------------------------------------------------------------
# Bun (daemon runtime)
# ----------------------------------------------------------------------------
ensure_bun() {
    if command -v bun &>/dev/null; then ok "Bun $(bun -v) already installed"; return; fi
    info "Installing Bun..."
    curl -fsSL https://bun.sh/install | bash -s "bun-v1.4.0" >/dev/null 2>&1 \
        || curl -fsSL https://bun.sh/install | bash >/dev/null 2>&1
    export PATH="$HOME/.bun/bin:$PATH"
    command -v bun &>/dev/null || die "Bun install failed"
    ok "Bun $(bun -v) installed"
}

# ----------------------------------------------------------------------------
# Panel: PostgreSQL + Redis
# ----------------------------------------------------------------------------
setup_panel_db() {
    info "Installing PostgreSQL + Redis..."
    case "$PKG" in
        apt) pkg_install postgresql postgresql-contrib redis-server ;;
        dnf) pkg_install postgresql-server postgresql redis ;;
        pacman) pkg_install postgresql redis ;;
        apk) pkg_install postgresql redis ;;
    esac

    if command -v systemctl &>/dev/null; then
        systemctl enable --now postgresql redis-server redis 2>/dev/null || true
    fi
    for i in $(seq 1 20); do
        su postgres -c "pg_isready" >/dev/null 2>&1 && break
        sleep 1
    done
    redis-cli ping >/dev/null 2>&1 || { info "Starting redis manually..."; redis-server --daemonize yes >/dev/null 2>&1 || true; }
    ok "PostgreSQL + Redis ready"
}

# ----------------------------------------------------------------------------
# Panel install
# ----------------------------------------------------------------------------
grab_repo() {
    local target="$1" sub="$2"
    if [[ -d "$target" ]]; then
        info "$target exists - updating..."
        cd "$target" || die "cannot cd $target"
        git fetch origin "$GIT_BRANCH" >/dev/null 2>&1 || true
        git reset --hard "origin/$GIT_BRANCH" >/dev/null 2>&1 || true
    else
        rm -rf "/tmp/airlink-clone"
        git clone --depth 1 --branch "$GIT_BRANCH" "$GIT_REPO" /tmp/airlink-clone >/dev/null 2>&1 \
            || die "Failed to download repo"
        mkdir -p "$(dirname "$target")"
        mv "/tmp/airlink-clone/$sub" "$target"
        rm -rf /tmp/airlink-clone
    fi
    ok "Source ready at $target"
}

install_panel() {
    echo
    echo "  ${BOLD}${C_CYAN}Installing Airlink Panel${RESET}"
    echo

    ensure_base_deps
    ensure_node
    ensure_docker
    setup_panel_db

    grab_repo "$PANEL_DIR" "panel-main"

    cd "$PANEL_DIR" || die "panel directory missing"

    [[ -f example.env ]] && cp example.env .env
    local secret_was_placeholder=0
    grep -q '^SESSION_SECRET="change_me"' .env && secret_was_placeholder=1
    if [[ $secret_was_placeholder -eq 1 ]]; then
        local secret; secret=$(openssl rand -hex 32)
        sed -i "s/^SESSION_SECRET=.*/SESSION_SECRET=\"$secret\"/" .env
    fi

    local db_pass; db_pass=$(openssl rand -hex 24)
    local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}'); [[ -z "$ip" ]] && ip="127.0.0.1"

    su postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='airlink'\"" | grep -q 1 \
        || su postgres -c "psql -c \"CREATE ROLE airlink WITH LOGIN PASSWORD '$db_pass' SUPERUSER\""

    # Rewrite DATABASE_URL / REDIS_URL in .env to match what's actually installed
    replace_env() { # key value
        sed -i "s|^$1=.*|$1=\"$2\"|" .env
    }
    replace_env DATABASE_URL "postgresql://airlink:$db_pass@127.0.0.1:5432/airlink"
    replace_env REDIS_URL "redis://127.0.0.1:6379"
    replace_env URL "http://$ip:$PANEL_PORT"
    replace_env PORT "$PANEL_PORT"
    replace_env NODE_ENV "production"
    replace_env PGPASSWORD "$db_pass"

    ok ".env configured"

    info "Installing dependencies (this takes a while)..."
    pnpm install --no-frozen-lockfile >/dev/null 2>&1 || die "pnpm install failed"
    pnpm approve-builds --all >/dev/null 2>&1 || true

    info "Running database migrations..."
    pnpm exec prisma generate >/dev/null 2>&1 || die "prisma generate failed"
    pnpm exec prisma db push >/dev/null 2>&1 || die "prisma db push failed"

    info "Building panel..."
    pnpm run build >/dev/null 2>&1 || die "panel build failed"

    register_panel_service
    ok "Panel installed"
}

register_panel_service() {
    if ! command -v systemctl &>/dev/null; then
        info "No systemd - start panel manually with: cd $PANEL_DIR && pnpm run start"
        return
    fi
    local pnpm_bin; pnpm_bin=$(command -v pnpm)
    cat > /etc/systemd/system/airlink-panel.service <<SVCEOF
[Unit]
Description=Airlink Panel
After=network.target postgresql.service redis-server.service redis.service

[Service]
Type=simple
User=root
WorkingDirectory=$PANEL_DIR
EnvironmentFile=$PANEL_DIR/.env
ExecStart=$pnpm_bin run start
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable --now airlink-panel >/dev/null 2>&1 || true
    ok "Panel service registered (airlink-panel)"
}

# ----------------------------------------------------------------------------
# Daemon / Node install
# ----------------------------------------------------------------------------
install_daemon() {
    echo
    echo "  ${BOLD}${C_CYAN}Installing Airlink Node (Daemon)${RESET}"
    echo

    ensure_base_deps
    ensure_docker
    ensure_bun

    mkdir -p "$DAEMON_DIR" "$SFTP_BASE"
    grab_repo "$DAEMON_DIR" "daemon-main/daemon-main"

    cd "$DAEMON_DIR" || die "daemon directory missing"

    info "Installing daemon dependencies..."
    bun install >/dev/null 2>&1 || die "bun install failed"

    read -p "  Panel URL (e.g. http://1.2.3.4:3000): " PANEL_URL
    PANEL_URL="${PANEL_URL%/}"
    [[ -n "$PANEL_URL" ]] || die "Panel URL required"

    default_key=$(openssl rand -hex 32)
    read -p "  Node key (from Admin > Nodes > Create) [enter for random]: " NODE_KEY
    NODE_KEY="${NODE_KEY:-$default_key}"

    cat > "$DAEMON_DIR/.env" <<ENVEOF
REMOTE=$(echo "$PANEL_URL" | cut -d/ -f3 | cut -d: -f1)
KEY=${NODE_KEY}
PORT=${DAEMON_PORT}
DEBUG=false
VERSION=3.0.0
STATS_INTERVAL=10000
CONTAINER_RUNTIME=docker
REQUIRE_HMAC=true
ALLOWED_IPS=
BEHIND_PROXY=false
SFTP_PORT=3004
ENVEOF
    ok ".env configured"

    register_daemon_service
    ok "Node installed. If you used a random key, register it in the panel: $NODE_KEY"
}

register_daemon_service() {
    if ! command -v systemctl &>/dev/null; then
        info "No systemd - start daemon manually with: cd $DAEMON_DIR && bun run start"
        return
    fi
    local bun_bin; bun_bin=$(command -v bun)
    cat > /etc/systemd/system/airlink-daemon.service <<SVCEOF
[Unit]
Description=Airlink Daemon
After=network.target docker.service

[Service]
Type=simple
User=root
WorkingDirectory=$DAEMON_DIR
EnvironmentFile=$DAEMON_DIR/.env
ExecStart=$bun_bin run start
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable --now airlink-daemon >/dev/null 2>&1 || true
    ok "Daemon service registered (airlink-daemon)"
}

# ----------------------------------------------------------------------------
# Menu
# ----------------------------------------------------------------------------
show_menu() {
    while true; do
        clear 2>/dev/null || true
        echo
        echo "  ${BOLD}  _    ___ ____  _     ___ _   _ _  __${RESET}"
        echo "  ${BOLD} / \\  |_ _|  _ \\| |   |_ _| \\ | | |/ /${RESET}"
        echo "  ${BOLD}/ _ \\  | || |_) | |    | ||  \\| | ' / ${RESET}"
        echo "  ${BOLD}/ ___ \\ | ||  _ <| |___ | || |\\  | . \\ ${RESET}"
        echo "  ${BOLD}/_/   \\_\\___|_| \\_\\_____|___|_| \\_|_|\\_\\${RESET}"
        echo
        echo "  ${C_GRAY}Airlink Manager v${VERSION}${RESET}"
        echo
        echo "  ${BOLD}1${RESET})  Install Panel"
        echo "  ${BOLD}2${RESET})  Install Node (Daemon)"
        echo "  ${BOLD}0${RESET})  Exit"
        echo
        read -rp "  Select option [0-2]: " choice
        case "$choice" in
            1) install_panel ;;
            2) install_daemon ;;
            0) echo "  Bye."; exit 0 ;;
            *) echo "  ${C_RED}Invalid option${RESET}"; sleep 1 ;;
        esac
    done
}

# ----------------------------------------------------------------------------
# CLI flags: --panel-only | --daemon-only | --version
# ----------------------------------------------------------------------------
case "${1:-}" in
    --panel-only) detect_os; install_panel; exit 0 ;;
    --daemon-only) detect_os; install_daemon; exit 0 ;;
    --version) echo "$VERSION"; exit 0 ;;
esac

detect_os
show_menu