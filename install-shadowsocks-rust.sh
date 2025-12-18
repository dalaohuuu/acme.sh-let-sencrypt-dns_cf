#!/usr/bin/env bash
# install-shadowsocks-rust.sh
#
# Minimal installer for shadowsocks-rust (ssserver):
# - Downloads ssserver from GitHub releases
# - Writes config(s) WITHOUT jq/python using strict input validation
# - Creates systemd services and enables autostart
#
# No firewall operations. No dependency auto-install.
#
# Required:
#   --method <METHOD>
#
# Choose ONE mode:
#   A) Multi-port (recommended): --entry NAME:PORT:PASS (repeatable, >=1)
#   B) Single-port: --port <PORT> and --password <PASS>
#
# Optional:
#   --mode tcp_only|tcp_and_udp (default tcp_only)
#   --timeout <SECONDS> (default 300)
#   --tag <TAG|latest> (default latest)

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

BIN_PATH="/usr/local/bin/ssserver"
CONF_DIR="/etc/shadowsocks-rust"
UNIT_DIR="/etc/systemd/system"

SS_USER="shadowsocks"
SS_GROUP="shadowsocks"

INSTALL_DIR=""

METHOD=""
MODE="tcp_only"
TIMEOUT="300"
RELEASE_TAG="latest"

# Single-port (legacy/compatible)
PORT=""
SINGLE_PASSWORD=""

# Multi-port
ENTRIES=() # NAME:PORT:PASS

DRY_RUN="false"

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
  sudo ./install-shadowsocks-rust.sh --method chacha20-ietf-poly1305 [multi-port entries...] [options]

Required:
  --method <METHOD>              Encryption method (e.g. chacha20-ietf-poly1305)

Choose ONE mode:

A) Multi-port (recommended):
  --entry <NAME:PORT:PASS>       Repeatable. Each entry becomes one ssserver instance.
                                 Example: --entry A1:62666:PASS_A1 --entry A2:62667:PASS_A2

B) Single-port:
  --port <PORT>                  Listening port
  --password <PASS>              Password

Options:
  --mode <tcp_only|tcp_and_udp>  Default: tcp_only
  --timeout <SECONDS>            Default: 300
  --tag <TAG|latest>             Default: latest
  --dry-run                      Print only
  -h, --help                     Show help

IMPORTANT (minimal JSON writer):
  Inputs are strictly validated (no jq/python JSON escaping).

Allowed formats:
  NAME   : [A-Za-z0-9_-]{1,32}
  PASS   : [A-Za-z0-9._~+=-]{8,128}
  METHOD : [A-Za-z0-9._+-]{3,64}

Examples:
  # Multi-port (best for "multi A nodes -> B"):
  sudo ./install-shadowsocks-rust.sh \
    --method chacha20-ietf-poly1305 \
    --mode tcp_only \
    --entry A1:62666:PASS_A1_12345678 \
    --entry A2:62667:PASS_A2_12345678

  # Single-port:
  sudo ./install-shadowsocks-rust.sh \
    --method chacha20-ietf-poly1305 \
    --port 62666 \
    --password PASS_A1_12345678
EOF
}

re_match() { [[ "$1" =~ $2 ]]; }

# -------- arg parse --------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --method) METHOD="${2:-}"; shift 2;;
    --mode) MODE="${2:-}"; shift 2;;
    --timeout) TIMEOUT="${2:-}"; shift 2;;
    --tag) RELEASE_TAG="${2:-}"; shift 2;;

    --entry) ENTRIES+=("${2:-}"); shift 2;;

    --port) PORT="${2:-}"; shift 2;;
    --password) SINGLE_PASSWORD="${2:-}"; shift 2;;

    --dry-run) DRY_RUN="true"; shift 1;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1 (use --help)";;
  esac
done

validate_common() {
  [[ -n "$METHOD" ]] || die "--method is required"
  re_match "$METHOD" '^[A-Za-z0-9._+-]{3,64}$' || die "--method contains unsupported characters"

  case "$MODE" in
    tcp_only|tcp_and_udp) ;;
    *) die "--mode must be tcp_only or tcp_and_udp" ;;
  esac

  re_match "$TIMEOUT" '^[0-9]+$' || die "--timeout must be a number"
}

validate_entry() {
  local entry="$1"
  # NAME:PORT:PASS
  # NAME cannot contain ':', PASS cannot contain ':'
  [[ "$entry" == *:*:* ]] || die "--entry must be NAME:PORT:PASS (got: $entry)"

  local name="${entry%%:*}"
  local rest="${entry#*:}"
  local port="${rest%%:*}"
  local pass="${rest#*:}"

  re_match "$name" '^[A-Za-z0-9_-]{1,32}$' || die "Entry NAME '$name' invalid (allowed: [A-Za-z0-9_-]{1,32})"
  re_match "$port" '^[0-9]+$' || die "Entry PORT '$port' must be a number"
  (( port >= 1 && port <= 65535 )) || die "Entry PORT '$port' out of range"
  re_match "$pass" '^[A-Za-z0-9._~+=-]{8,128}$' || die "Entry PASS for '$name' invalid (allowed: [A-Za-z0-9._~+=-]{8,128})"
}

validate_single() {
  [[ -n "$PORT" ]] || die "--port is required for single-port mode"
  [[ -n "$SINGLE_PASSWORD" ]] || die "--password is required for single-port mode"

  re_match "$PORT" '^[0-9]+$' || die "--port must be a number"
  (( PORT >= 1 && PORT <= 65535 )) || die "--port out of range"
  re_match "$SINGLE_PASSWORD" '^[A-Za-z0-9._~+=-]{8,128}$' || die "--password must match [A-Za-z0-9._~+=-]{8,128}"
}

validate_mode_choice() {
  # You must choose either multi-port or single-port, not both
  if [[ ${#ENTRIES[@]} -gt 0 ]]; then
    if [[ -n "$PORT" || -n "$SINGLE_PASSWORD" ]]; then
      die "Use either multi-port (--entry ...) OR single-port (--port + --password), not both"
    fi
    for e in "${ENTRIES[@]}"; do validate_entry "$e"; done
  else
    # no entries -> single-port
    validate_single
  fi
}

ensure_deps() {
  has_cmd curl || die "curl not found (install it manually)"
  has_cmd tar  || die "tar not found (install it manually)"
  has_cmd xz   || warn "xz not found; extracting .tar.xz may fail. Install xz/xz-utils."
}

detect_arch_triple() {
  case "$(uname -m)" in
    x86_64|amd64) echo "x86_64-unknown-linux-gnu" ;;
    aarch64|arm64) echo "aarch64-unknown-linux-gnu" ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
  esac
}

get_latest_tag() {
  local tag
  tag="$(curl -fsSL https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest \
    | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  [[ -n "$tag" ]] || die "Failed to detect latest release tag from GitHub"
  echo "$tag"
}

install_ssserver() {
  local triple tag tmp base1 base2 url1 url2
  triple="$(detect_arch_triple)"
  tag="$RELEASE_TAG"
  [[ "$tag" != "latest" ]] || tag="$(get_latest_tag)"

  tmp="$(mktemp -d)"
  INSTALL_DIR="$tmp"

  base1="shadowsocks-${tag}.${triple}.tar.xz"
  base2="shadowsocks-${tag#v}.${triple}.tar.xz"
  url1="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${tag}/${base1}"
  url2="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${tag}/${base2}"

  log "Downloading ssserver (${tag}, ${triple})"
  if curl -fL --retry 3 --retry-delay 1 -o "${tmp}/pkg.tar.xz" "$url1" >/dev/null 2>&1; then
    :
  elif curl -fL --retry 3 --retry-delay 1 -o "${tmp}/pkg.tar.xz" "$url2" >/dev/null 2>&1; then
    :
  else
    die "Failed to download release asset. Tried:
  - ${url1}
  - ${url2}"
  fi

  run "tar -C '$tmp' -xJf '$tmp/pkg.tar.xz'"

  local bin
  bin="$(find "$tmp" -type f -name ssserver -perm -u+x | head -n1 || true)"
  [[ -n "$bin" ]] || die "ssserver binary not found in release package"

  run "install -m 0755 '$bin' '$BIN_PATH'"
  log "Installed ssserver to $BIN_PATH"
}

create_user_and_dirs() {
  if ! id -u "$SS_USER" >/dev/null 2>&1; then
    log "Creating system user: $SS_USER"
    run "useradd --system --no-create-home --shell /usr/sbin/nologin '$SS_USER'"
  fi
  run "mkdir -p '$CONF_DIR'"
  run "chmod 0755 '$CONF_DIR'"
}

write_config_file() {
  local name="$1"
  local port="$2"
  local pass="$3"
  local conf_path="${CONF_DIR}/${name}.json"

  log "Writing config: ${conf_path}"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run] would write ${conf_path}"
    return 0
  fi

  cat > "$conf_path" <<EOF
{
  "server": "0.0.0.0",
  "server_port": ${port},
  "method": "${METHOD}",
  "mode": "${MODE}",
  "timeout": ${TIMEOUT},
  "password": "${pass}",
  "log": { "level": "warn" }
}
EOF

  chmod 0644 "$conf_path"
}

write_unit_file() {
  local name="$1"
  local conf_path="${CONF_DIR}/${name}.json"
  local unit_name="ssserver-${name}.service"
  local unit_path="${UNIT_DIR}/${unit_name}"

  log "Writing systemd unit: ${unit_name}"

  local tmp
  tmp="$(mktemp)"

  cat > "$tmp" <<EOF
[Unit]
Description=Shadowsocks Rust Server (${name})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SS_USER}
Group=${SS_GROUP}
ExecStart=${BIN_PATH} -c ${conf_path}
Restart=on-failure
RestartSec=2
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF

  run "install -m 0644 '$tmp' '$unit_path'"
  run "rm -f '$tmp'"
}

enable_start_unit() {
  local name="$1"
  local unit="ssserver-${name}.service"
  run "systemctl daemon-reload"
  run "systemctl enable --now '${unit}'"
}

cleanup() {
  if [[ -n "${INSTALL_DIR:-}" && -d "${INSTALL_DIR:-}" ]]; then
    rm -rf "${INSTALL_DIR}" || true
  fi
}
trap cleanup EXIT

print_summary() {
  echo
  log "Done."
  echo "  binary : ${BIN_PATH}"
  echo "  config : ${CONF_DIR}/"
  echo "  method : ${METHOD}"
  echo "  mode   : ${MODE}"
  echo
  echo "Commands:"
  if [[ ${#ENTRIES[@]} -gt 0 ]]; then
    echo "  systemctl list-units 'ssserver-*' --no-pager"
    echo "  journalctl -u 'ssserver-*' -f"
  else
    # single-port mode uses name=PORT for consistency
    echo "  systemctl status ssserver-${PORT} --no-pager"
    echo "  journalctl -u ssserver-${PORT} -f"
  fi
}

main() {
  need_root
  validate_common
  validate_mode_choice
  ensure_deps

  log "Starting install (dry-run=${DRY_RUN})"
  install_ssserver
  create_user_and_dirs

  if [[ ${#ENTRIES[@]} -gt 0 ]]; then
    for entry in "${ENTRIES[@]}"; do
      local name="${entry%%:*}"
      local rest="${entry#*:}"
      local port="${rest%%:*}"
      local pass="${rest#*:}"
      write_config_file "$name" "$port" "$pass"
      write_unit_file "$name"
      enable_start_unit "$name"
    done
  else
    # single-port mode: name by port for consistent unit naming
    local name="${PORT}"
    write_config_file "$name" "$PORT" "$SINGLE_PASSWORD"
    write_unit_file "$name"
    enable_start_unit "$name"
  fi

  print_summary
}

main
