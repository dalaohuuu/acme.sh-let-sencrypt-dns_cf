#!/usr/bin/env bash
# install-shadowsrocks-rust.sh
#
# Install shadowsocks-rust (ssserver), generate config safely,
# set up systemd autostart. NO FIREWALL OPERATIONS.
#
# Suitable for production environments where firewall is managed externally.

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

SS_USER="shadowsocks"
SS_GROUP="shadowsocks"
BIN_PATH="/usr/local/bin/ssserver"
CONF_DIR="/etc/shadowsocks-rust"
CONF_PATH="${CONF_DIR}/config.json"
UNIT_PATH="/etc/systemd/system/ssserver.service"
STATE_DIR="/var/lib/shadowsocks-rust"
LOG_DIR="/var/log/shadowsocks-rust"

# Defaults
PORT=""
METHOD="chacha20-ietf-poly1305"
MODE="tcp_only"           # tcp_only | tcp_and_udp
TIMEOUT="300"
RELEASE_TAG="latest"
INSTALL_DIR=""

USERS=()                  # NAME:PASS
SINGLE_PASSWORD=""
AUTO_INSTALL_DEPS="false"
INSTALL_JQ="auto"
DRY_RUN="false"

# ---------- helpers ----------
log()  { echo -e "[+] $*"; }
warn() { echo -e "[!] $*" >&2; }
die()  { echo -e "[x] $*" >&2; exit 1; }

has_cmd() { command -v "$1" >/dev/null 2>&1; }

run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run] $*"
  else
    eval "$@"
  fi
}

need_root() {
  [[ "${EUID}" -eq 0 ]] || die "Please run as root (sudo)"
}

usage() {
  cat <<'EOF'
Usage:
  sudo ./install-shadowsrocks-rust.sh --port 62666 [options]

Required:
  --port <PORT>                 Listening port

Auth (choose ONE):
  --password <PASS>             Single user password
  --user <NAME:PASS>            Multi-user entry (repeatable)

Options:
  --method <METHOD>             Default: chacha20-ietf-poly1305
  --mode <tcp_only|tcp_and_udp> Default: tcp_only
  --timeout <SECONDS>           Default: 300
  --tag <TAG|latest>            shadowsocks-rust release version

Deps / JSON:
  --install-deps                Auto install deps (apt/yum/dnf)
  --install-jq                  Install jq for safe JSON
  --no-install-jq               Do not install jq
  --dry-run                     Print only

Other:
  -h, --help                    Show this help
EOF
}

# ---------- parse args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) PORT="$2"; shift 2;;
    --method) METHOD="$2"; shift 2;;
    --mode) MODE="$2"; shift 2;;
    --timeout) TIMEOUT="$2"; shift 2;;
    --tag) RELEASE_TAG="$2"; shift 2;;
    --password) SINGLE_PASSWORD="$2"; shift 2;;
    --user) USERS+=("$2"); shift 2;;
    --install-deps) AUTO_INSTALL_DEPS="true"; shift;;
    --install-jq) INSTALL_JQ="true"; shift;;
    --no-install-jq) INSTALL_JQ="false"; shift;;
    --dry-run) DRY_RUN="true"; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1";;
  esac
done

# ---------- validation ----------
validate() {
  [[ -n "$PORT" ]] || die "--port is required"
  [[ "$PORT" =~ ^[0-9]+$ ]] || die "Invalid port"
  (( PORT >= 1 && PORT <= 65535 )) || die "Port out of range"

  [[ "$MODE" == "tcp_only" || "$MODE" == "tcp_and_udp" ]] || die "Invalid mode"

  if [[ -n "$SINGLE_PASSWORD" && ${#USERS[@]} -gt 0 ]]; then
    die "Use --password OR --user, not both"
  fi
  if [[ -z "$SINGLE_PASSWORD" && ${#USERS[@]} -eq 0 ]]; then
    die "You must specify --password or at least one --user"
  fi
}

# ---------- deps ----------
detect_pm() {
  has_cmd apt-get && echo apt && return
  has_cmd dnf && echo dnf && return
  has_cmd yum && echo yum && return
  echo none
}

install_deps() {
  [[ "$AUTO_INSTALL_DEPS" == "true" ]] || return 0

  local pm
  pm="$(detect_pm)"
  [[ "$pm" != "none" ]] || die "No supported package manager found"

  log "Installing dependencies via $pm"

  case "$pm" in
    apt)
      run "apt-get update -y"
      run "apt-get install -y curl tar xz-utils ca-certificates python3"
      [[ "$INSTALL_JQ" == "true" || "$INSTALL_JQ" == "auto" ]] && run "apt-get install -y jq"
      ;;
    dnf|yum)
      run "$pm -y install curl tar xz ca-certificates python3"
      [[ "$INSTALL_JQ" == "true" || "$INSTALL_JQ" == "auto" ]] && run "$pm -y install jq || true"
      ;;
  esac
}

ensure_deps() {
  has_cmd curl || die "curl not found"
  has_cmd tar || die "tar not found"
}

# ---------- install ssserver ----------
detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "x86_64-unknown-linux-gnu" ;;
    aarch64|arm64) echo "aarch64-unknown-linux-gnu" ;;
    *) die "Unsupported architecture" ;;
  esac
}

get_latest_tag() {
  curl -fsSL https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest \
    | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p'
}

install_ssserver() {
  local arch tag url tmp
  arch="$(detect_arch)"
  tag="$RELEASE_TAG"
  [[ "$tag" != "latest" ]] || tag="$(get_latest_tag)"

  tmp="$(mktemp -d)"
  INSTALL_DIR="$tmp"

  url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${tag}/shadowsocks-${tag}.${arch}.tar.xz"

  log "Downloading ssserver $tag"
  run "curl -fL -o '$tmp/pkg.tar.xz' '$url'"
  run "tar -xJf '$tmp/pkg.tar.xz' -C '$tmp'"

  local bin
  bin="$(find "$tmp" -name ssserver -type f | head -n1)"
  [[ -n "$bin" ]] || die "ssserver not found"

  run "install -m 0755 '$bin' '$BIN_PATH'"
}

# ---------- config ----------
write_config() {
  run "mkdir -p '$CONF_DIR'"

  if has_cmd jq; then
    log "Writing config using jq"
    if [[ -n "$SINGLE_PASSWORD" ]]; then
      run "jq -n \
        --argjson port $PORT \
        --arg method '$METHOD' \
        --arg mode '$MODE' \
        --argjson timeout $TIMEOUT \
        --arg password '$SINGLE_PASSWORD' \
        '{server:\"0.0.0.0\",server_port:$port,method:$method,mode:$mode,timeout:$timeout,password:$password,log:{level:\"warn\"}}' \
        > '$CONF_PATH'"
    else
      local users_json="[]"
      for up in "${USERS[@]}"; do
        users_json="$(jq -cn --argjson a "$users_json" --arg n "${up%%:*}" --arg p "${up#*:}" '$a+[{name:$n,password:$p}]')"
      done
      run "jq -n \
        --argjson port $PORT \
        --arg method '$METHOD' \
        --arg mode '$MODE' \
        --argjson timeout $TIMEOUT \
        --argjson users '$users_json' \
        '{server:\"0.0.0.0\",server_port:$port,method:$method,mode:$mode,timeout:$timeout,users:$users,log:{level:\"warn\"}}' \
        > '$CONF_PATH'"
    fi
  else
    die "jq not found. Install jq or use --install-jq"
  fi
}

# ---------- systemd ----------
setup_systemd() {
  log "Creating systemd service"

  cat > "$UNIT_PATH" <<EOF
[Unit]
Description=Shadowsocks Rust Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN_PATH -c $CONF_PATH
Restart=on-failure
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  run "systemctl daemon-reload"
  run "systemctl enable --now ssserver"
}

cleanup() {
  [[ -n "$INSTALL_DIR" ]] && rm -rf "$INSTALL_DIR"
}
trap cleanup EXIT

main() {
  need_root
  validate
  install_deps
  ensure_deps
  install_ssserver
  write_config
  setup_systemd

  log "Installation complete."
  log "Config: $CONF_PATH"
  log "Service: systemctl status ssserver"
}

main
