#!/usr/bin/env bash
# install-shadowsocks-rust.sh
#
# Minimal installer for shadowsocks-rust (ssserver):
# - Downloads ssserver from GitHub releases
# - Writes config.json (WITHOUT jq/python) using strict input validation
# - Sets up systemd (autostart)
#
# No firewall operations. No dependency auto-install.
#
# Required:
#   --port <PORT>
#   --method <METHOD>
# And one of:
#   --password <PASS>
#   --user <NAME:PASS>   (repeatable)

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

BIN_PATH="/usr/local/bin/ssserver"
CONF_DIR="/etc/shadowsocks-rust"
CONF_PATH="${CONF_DIR}/config.json"
UNIT_PATH="/etc/systemd/system/ssserver.service"

SS_USER="shadowsocks"
SS_GROUP="shadowsocks"

INSTALL_DIR=""

PORT=""
METHOD=""
MODE="tcp_only"     # tcp_only | tcp_and_udp
TIMEOUT="300"
RELEASE_TAG="latest"

SINGLE_PASSWORD=""
USERS=()            # NAME:PASS

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
  sudo ./install-shadowsocks-rust.sh --port 62666 --method chacha20-ietf-poly1305 [options]

Required:
  --port <PORT>                 Listening port
  --method <METHOD>             Encryption method (e.g. chacha20-ietf-poly1305)

Auth (choose ONE):
  --password <PASS>             Single user password
  --user <NAME:PASS>            Multi-user entry (repeatable)

Options:
  --mode <tcp_only|tcp_and_udp> Default: tcp_only
  --timeout <SECONDS>           Default: 300
  --tag <TAG|latest>            Release tag (default: latest)
  --dry-run                     Print only
  -h, --help                    Show help

Notes (IMPORTANT):
  This minimal version does NOT use jq/python to write JSON.
  Therefore NAME/PASS/METHOD are validated with strict allowed characters.

Allowed formats:
  NAME   : [A-Za-z0-9_-]{1,32}
  PASS   : [A-Za-z0-9._~+=-]{8,128}
  METHOD : [A-Za-z0-9._+-]{3,64}

Examples:
  sudo ./install-shadowsocks-rust.sh \
    --port 62666 \
    --method chacha20-ietf-poly1305 \
    --mode tcp_only \
    --user A1:PASS_A1_12345678 \
    --user A2:PASS_A2_12345678
EOF
}

# -------- arg parse --------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) PORT="${2:-}"; shift 2;;
    --method) METHOD="${2:-}"; shift 2;;
    --mode) MODE="${2:-}"; shift 2;;
    --timeout) TIMEOUT="${2:-}"; shift 2;;
    --tag) RELEASE_TAG="${2:-}"; shift 2;;
    --password) SINGLE_PASSWORD="${2:-}"; shift 2;;
    --user) USERS+=("${2:-}"); shift 2;;
    --dry-run) DRY_RUN="true"; shift 1;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1 (use --help)";;
  esac
done

# -------- validation helpers --------
re_match() {
  local value="$1"
  local pattern="$2"
  [[ "$value" =~ $pattern ]]
}

validate() {
  [[ -n "$PORT" ]] || die "--port is required"
  re_match "$PORT" '^[0-9]+$' || die "--port must be a number"
  (( PORT >= 1 && PORT <= 65535 )) || die "--port must be in 1..65535"

  [[ -n "$METHOD" ]] || die "--method is required"
  # METHOD safe charset for JSON without escaping
  re_match "$METHOD" '^[A-Za-z0-9._+-]{3,64}$' || die "--method contains unsupported characters"

  case "$MODE" in
    tcp_only|tcp_and_udp) ;;
    *) die "--mode must be tcp_only or tcp_and_udp" ;;
  esac

  re_match "$TIMEOUT" '^[0-9]+$' || die "--timeout must be a number"

  if [[ -n "$SINGLE_PASSWORD" && ${#USERS[@]} -gt 0 ]]; then
    die "Use --password OR --user ... (not both)"
  fi
  if [[ -z "$SINGLE_PASSWORD" && ${#USERS[@]} -eq 0 ]]; then
    die "You must specify --password or at least one --user NAME:PASS"
  fi

  # Password validation (safe charset, length)
  if [[ -n "$SINGLE_PASSWORD" ]]; then
    re_match "$SINGLE_PASSWORD" '^[A-Za-z0-9._~+=-]{8,128}$' || die "--password must match [A-Za-z0-9._~+=-]{8,128}"
  fi

  # Multi-user validation
  if [[ ${#USERS[@]} -gt 0 ]]; then
    for up in "${USERS[@]}"; do
      [[ "$up" == *:* ]] || die "--user must be NAME:PASS (got: $up)"
      local name="${up%%:*}"
      local pass="${up#*:}"
      re_match "$name" '^[A-Za-z0-9_-]{1,32}$' || die "User name '$name' must match [A-Za-z0-9_-]{1,32}"
      re_match "$pass" '^[A-Za-z0-9._~+=-]{8,128}$' || die "Password for '$name' must match [A-Za-z0-9._~+=-]{8,128}"
    done
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

write_config_json_minimal() {
  log "Writing config to $CONF_PATH (minimal JSON writer)"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run] would write ${CONF_PATH}"
    return 0
  fi

  umask 022

  if [[ -n "$SINGLE_PASSWORD" ]]; then
    cat > "$CONF_PATH" <<EOF
{
  "server": "0.0.0.0",
  "server_port": ${PORT},
  "method": "${METHOD}",
  "mode": "${MODE}",
  "timeout": ${TIMEOUT},
  "password": "${SINGLE_PASSWORD}",
  "log": { "level": "warn" }
}
EOF
  else
    {
      echo "{"
      echo "  \"server\": \"0.0.0.0\","
      echo "  \"server_port\": ${PORT},"
      echo "  \"method\": \"${METHOD}\","
      echo "  \"mode\": \"${MODE}\","
      echo "  \"timeout\": ${TIMEOUT},"
      echo "  \"users\": ["
      local i=0
      local n="${#USERS[@]}"
      for up in "${USERS[@]}"; do
        i=$((i+1))
        local name="${up%%:*}"
        local pass="${up#*:}"
        if [[ $i -lt $n ]]; then
          echo "    { \"name\": \"${name}\", \"password\": \"${pass}\" },"
        else
          echo "    { \"name\": \"${name}\", \"password\": \"${pass}\" }"
        fi
      done
      echo "  ],"
      echo "  \"log\": { \"level\": \"warn\" }"
      echo "}"
    } > "$CONF_PATH"
  fi

  chmod 0644 "$CONF_PATH"
}

write_systemd_unit() {
  log "Writing systemd unit to $UNIT_PATH"

  local tmp
  tmp="$(mktemp)"

  cat > "$tmp" <<EOF
[Unit]
Description=Shadowsocks Rust Server (ssserver)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SS_USER}
Group=${SS_GROUP}
ExecStart=${BIN_PATH} -c ${CONF_PATH}
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

  run "install -m 0644 '$tmp' '$UNIT_PATH'"
  run "rm -f '$tmp'"

  run "systemctl daemon-reload"
  run "systemctl enable --now ssserver"
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
  echo "  config : ${CONF_PATH}"
  echo "  systemd: ssserver (enabled)"
  echo "  port   : ${PORT}"
  echo "  method : ${METHOD}"
  echo "  mode   : ${MODE}"
  echo
  echo "Commands:"
  echo "  systemctl status ssserver --no-pager"
  echo "  journalctl -u ssserver -f"
  echo "  ss -lntup | grep ${PORT} || true"
}

main() {
  need_root
  validate
  ensure_deps

  log "Starting install (dry-run=${DRY_RUN})"
  install_ssserver
  create_user_and_dirs
  write_config_json_minimal
  write_systemd_unit
  print_summary
}

main
