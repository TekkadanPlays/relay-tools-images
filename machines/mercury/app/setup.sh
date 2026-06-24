#!/usr/bin/env bash
# Local development setup for gc_index_relay (run on your host — NOT inside app Docker images).
# Production/runtime images get dependencies from docker/server.Dockerfile (release build + runtime packages).
# Safe to run multiple times — all steps are idempotent.
#
# Requirements:
#   - Docker must already be installed (https://docs.docker.com/engine/install/)
#   - sudo access to install OS packages (apt-get on Debian/Ubuntu, dnf/yum on Fedora/RHEL)
#
# Debian / Ubuntu: Erlang + Elixir are installed from Team RabbitMQ’s apt repositories, as
# recommended on https://elixir-lang.org/install.html (Launchpad PPA on Ubuntu; Cloudsmith
# erlang debs on Debian amd64). Fedora/RHEL still use asdf-compiled Erlang.
#
# Usage:
#   chmod +x setup.sh
#   ./setup.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

ERLANG_VERSION="28.4.1"
ELIXIR_VERSION="1.19.5-otp-28"

POSTGRES_HOST="localhost"
POSTGRES_PORT="5455"
POSTGRES_USER="postgres"
POSTGRES_PASSWORD="postgres"
POSTGRES_DB="gc_index_relay_dev"

DOCKER_CONTAINER_NAME="gc_age_db"
AGE_IMAGE="apache/age:release_PG17_1.6.0"

ASDF_DIR="$HOME/.asdf"
ASDF_VERSION="v0.15.0"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[setup]${NC} $*"; }
warn() { echo -e "${YELLOW}[ warn]${NC} $*"; }
err()  { echo -e "${RED}[error]${NC} $*" >&2; exit 1; }

require_cmd() {
  command -v "$1" &>/dev/null || err "'$1' is not installed or not on PATH. $2"
}

# Install modern Erlang + Elixir via RabbitMQ-maintained apt repos (Elixir install docs).
# Returns 0 on success, 1 to fall back to asdf.
install_elixir_erlang_via_rabbitmq_apt() {
  local id version
  [ -f /etc/os-release ] || return 1
  # shellcheck source=/dev/null
  . /etc/os-release
  id="${ID:-}"
  version="${VERSION_CODENAME:-}"

  if [ "$id" = "linuxmint" ]; then
    version="${UBUNTU_CODENAME:-$version}"
  fi

  case "$id" in
    ubuntu | pop | linuxmint)
      log "Installing Erlang + Elixir via RabbitMQ Erlang PPA (https://elixir-lang.org/install.html)..."
      sudo apt-get install -y software-properties-common
      sudo add-apt-repository -y ppa:rabbitmq/rabbitmq-erlang
      sudo apt-get update -qq
      sudo apt-get install -y git elixir erlang
      ;;
    debian)
      if [ "$(uname -m)" != "x86_64" ]; then
        warn "RabbitMQ Cloudsmith Erlang packages are amd64-only; use asdf on this architecture."
        return 1
      fi
      case "$version" in
        bullseye | bookworm | trixie)
          log "Installing Erlang via Team RabbitMQ apt + elixir (Debian ${version}; https://www.rabbitmq.com/docs/install-debian)..."
          sudo apt-get install -y curl gnupg apt-transport-https
          curl -1sLf "https://keys.openpgp.org/vks/v1/by-fingerprint/0A9AF2115F4687BD29803A206B73A36E6026DFCA" |
            sudo gpg --dearmor | sudo tee /usr/share/keyrings/com.rabbitmq.team.gpg >/dev/null
          sudo tee /etc/apt/sources.list.d/rabbitmq-erlang.list >/dev/null <<EOF
deb [arch=amd64 signed-by=/usr/share/keyrings/com.rabbitmq.team.gpg] https://deb1.rabbitmq.com/rabbitmq-erlang/debian/${version} ${version} main
deb [arch=amd64 signed-by=/usr/share/keyrings/com.rabbitmq.team.gpg] https://deb2.rabbitmq.com/rabbitmq-erlang/debian/${version} ${version} main
EOF
          sudo apt-get update -qq
          sudo apt-get install -y \
            erlang-base \
            erlang-asn1 \
            erlang-crypto \
            erlang-eldap \
            erlang-ftp \
            erlang-inets \
            erlang-mnesia \
            erlang-os-mon \
            erlang-parsetools \
            erlang-public-key \
            erlang-runtime-tools \
            erlang-snmp \
            erlang-ssl \
            erlang-syntax-tools \
            erlang-tftp \
            erlang-tools \
            erlang-xmerl
          sudo apt-get install -y git elixir
          ;;
        *)
          warn "Debian ${version:-unknown} not supported for RabbitMQ Erlang apt (expected bullseye, bookworm, or trixie)."
          return 1
          ;;
      esac
      ;;
    *)
      return 1
      ;;
  esac

  hash -r
  if ! command -v elixir &>/dev/null; then
    warn "elixir not found on PATH after apt install."
    return 1
  fi
  if ! elixir --version 2>/dev/null | grep -qE 'Elixir 1\.(1[5-9]|[2-9][0-9])'; then
    warn "Elixir from apt is below 1.15; falling back to asdf."
    return 1
  fi
  log "$(elixir --version 2>/dev/null | grep Elixir || true)"
  return 0
}

# ---------------------------------------------------------------------------
# 1. Pre-flight checks
# ---------------------------------------------------------------------------

log "Starting gc_index_relay local setup..."
echo

require_cmd docker "Install Docker first: https://docs.docker.com/engine/install/"
docker info &>/dev/null || err "Docker daemon is not running. Start it and try again."
log "Docker: $(docker --version)"

# ---------------------------------------------------------------------------
# 2. System build dependencies (Debian/Ubuntu, Fedora, RHEL-like)
# ---------------------------------------------------------------------------

install_system_deps_apt() {
  log "Installing system build dependencies via apt-get..."
  sudo apt-get update -qq
  sudo apt-get install -y \
    build-essential \
    autoconf \
    libtool \
    inotify-tools \
    git \
    curl \
    jq
}

# Fedora / RHEL / Alma / Rocky (dnf or yum). Includes openssl/ncurses headers for asdf Erlang builds.
install_system_deps_rpm() {
  local pm="$1"
  log "Installing system build dependencies via $pm..."
  sudo "$pm" install -y \
    gcc \
    gcc-c++ \
    make \
    autoconf \
    automake \
    libtool \
    inotify-tools \
    git \
    curl \
    jq \
    openssl-devel \
    ncurses-devel
}

if command -v apt-get &>/dev/null; then
  install_system_deps_apt
elif command -v dnf &>/dev/null; then
  install_system_deps_rpm dnf
elif command -v yum &>/dev/null; then
  install_system_deps_rpm yum
else
  warn "No supported package manager found (apt-get, dnf, or yum) — skipping system package install."
  warn "Install manually (names differ by distro): C toolchain, autoconf, libtool, inotify-tools, git, curl, jq"
  warn "For asdf Erlang on Fedora/RHEL, you typically also need: openssl-devel, ncurses-devel"
fi

# ---------------------------------------------------------------------------
# 2b. Erlang + Elixir (apt on Debian/Ubuntu via RabbitMQ repos, else asdf)
# ---------------------------------------------------------------------------

ELIXIR_FROM_APT=0
if command -v apt-get &>/dev/null; then
  if install_elixir_erlang_via_rabbitmq_apt; then
    ELIXIR_FROM_APT=1
    log "Using apt-installed Erlang/Elixir (no asdf Erlang/Elixir steps)."
  else
    warn "RabbitMQ apt path skipped or failed — installing Erlang/Elixir with asdf."
  fi
fi

if [ "$ELIXIR_FROM_APT" -eq 0 ]; then
  # ---------------------------------------------------------------------------
  # 3. asdf version manager
  # ---------------------------------------------------------------------------

  if [ ! -d "$ASDF_DIR" ]; then
    log "Installing asdf $ASDF_VERSION..."
    git clone https://github.com/asdf-vm/asdf.git "$ASDF_DIR" --branch "$ASDF_VERSION"
  else
    log "asdf already installed at $ASDF_DIR"
  fi

  # shellcheck source=/dev/null
  source "$ASDF_DIR/asdf.sh"

  add_asdf_to_rc() {
    local rc="$1"
    local line='. "$HOME/.asdf/asdf.sh"'
    if [ -f "$rc" ] && ! grep -qF 'asdf/asdf.sh' "$rc"; then
      echo "" >> "$rc"
      echo "# asdf version manager" >> "$rc"
      echo "$line" >> "$rc"
      log "Added asdf to $rc (will take effect in new shells)"
    fi
  }
  add_asdf_to_rc "$HOME/.bashrc"
  add_asdf_to_rc "$HOME/.zshrc" 2>/dev/null || true

  # ---------------------------------------------------------------------------
  # 4. Erlang
  # ---------------------------------------------------------------------------

  asdf plugin add erlang 2>/dev/null || true

  if asdf list erlang 2>/dev/null | grep -qF "$ERLANG_VERSION"; then
    log "Erlang $ERLANG_VERSION already installed"
  else
    log "Installing Erlang $ERLANG_VERSION (compiles from source — takes a few minutes)..."
    asdf install erlang "$ERLANG_VERSION"
  fi

  asdf global erlang "$ERLANG_VERSION"

  # ---------------------------------------------------------------------------
  # 5. Elixir
  # ---------------------------------------------------------------------------

  asdf plugin add elixir 2>/dev/null || true

  if asdf list elixir 2>/dev/null | grep -qF "$ELIXIR_VERSION"; then
    log "Elixir $ELIXIR_VERSION already installed"
  else
    log "Installing Elixir $ELIXIR_VERSION..."
    asdf install elixir "$ELIXIR_VERSION"
  fi

  asdf global elixir "$ELIXIR_VERSION"
  log "$(elixir --version | grep 'Elixir')"
else
  hash -r
fi

# ---------------------------------------------------------------------------
# 6. Apache AGE database (Docker)
# ---------------------------------------------------------------------------

if docker ps -q --filter "name=^${DOCKER_CONTAINER_NAME}$" | grep -q .; then
  log "Database container '$DOCKER_CONTAINER_NAME' is already running"
elif docker ps -aq --filter "name=^${DOCKER_CONTAINER_NAME}$" | grep -q .; then
  log "Restarting existing database container '$DOCKER_CONTAINER_NAME'..."
  docker start "$DOCKER_CONTAINER_NAME"
else
  log "Starting Apache AGE database container..."
  docker run -d \
    --name "$DOCKER_CONTAINER_NAME" \
    -p "${POSTGRES_PORT}:5432" \
    -e POSTGRES_USER="$POSTGRES_USER" \
    -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
    -e POSTGRES_DB="$POSTGRES_DB" \
    "$AGE_IMAGE"
fi

log "Waiting for database to accept connections..."
until docker exec "$DOCKER_CONTAINER_NAME" pg_isready -U "$POSTGRES_USER" &>/dev/null; do
  sleep 1
done
log "Database is ready"

# ---------------------------------------------------------------------------
# 7. .env file
# ---------------------------------------------------------------------------

ENV_FILE="$PROJECT_DIR/.env"

if [ ! -f "$ENV_FILE" ]; then
  log "Writing .env with database credentials..."
  cat > "$ENV_FILE" <<EOF
export POSTGRES_HOST=$POSTGRES_HOST
export POSTGRES_PORT=$POSTGRES_PORT
export POSTGRES_USER=$POSTGRES_USER
export POSTGRES_PASSWORD=$POSTGRES_PASSWORD
export POSTGRES_DB=$POSTGRES_DB
export REQUIRE_DB=true
EOF
else
  log ".env already exists — skipping (delete it to regenerate)"
fi

# Export DB vars for this session so mix setup can connect. Do not export REQUIRE_DB here —
# that would make a follow-up `mix test.unit` in the same shell start the Repo. It is only in `.env` for integration tests.
export POSTGRES_HOST POSTGRES_PORT POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB

# ---------------------------------------------------------------------------
# 8. Mix setup (deps + database)
# ---------------------------------------------------------------------------

cd "$PROJECT_DIR"

if [ "$ELIXIR_FROM_APT" -eq 1 ]; then
  require_cmd mix "apt elixir package should provide mix; check PATH includes /usr/bin"
else
  require_cmd mix "asdf should provide mix; run: source \"\$HOME/.asdf/asdf.sh\" or open a new terminal"
fi

log "Installing Hex and Rebar..."
mix local.hex --force
mix local.rebar --force

log "Fetching dependencies..."
mix deps.get

log "Running mix setup (compile + create DB + migrate)..."
mix setup

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

echo
log "Setup complete!"
echo
if [ "$ELIXIR_FROM_APT" -eq 1 ]; then
  echo "  To start the server (system Elixir from apt):"
  echo "    cd \"$PROJECT_DIR\" && source .env && mix phx.server"
  echo
  echo "  Then open: http://localhost:4000"
  echo "  REST API:  http://localhost:4000/api/events"
  echo
  echo "  Integration tests:"
  echo "    source .env && mix test.integration"
  echo
  warn "If mix is not found in a new terminal, ensure /usr/bin is on your PATH."
else
  echo "  To start the server (use asdf’s mix — see warning below if mix is missing):"
  echo "    source \"\$HOME/.asdf/asdf.sh\"   # once per shell, if needed"
  echo "    cd \"$PROJECT_DIR\" && source .env && mix phx.server"
  echo
  echo "  Then open: http://localhost:4000"
  echo "  REST API:  http://localhost:4000/api/events"
  echo
  echo "  Integration tests: same shell with .env (includes REQUIRE_DB=true):"
  echo "    source .env && mix test.integration"
  echo
  warn "Open a new terminal (or run 'source ~/.bashrc') so asdf provides mix/elixir in future sessions."
fi
