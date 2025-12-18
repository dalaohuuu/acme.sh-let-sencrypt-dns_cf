#!/usr/bin/env bash
# install-shadowsrocks-rust.sh by ChatGPT5.2
# Install shadowsocks-rust (ssserver) on Linux, write config, set up systemd, and configure UFW.
#
# Enhancements:
#  - Optional auto-install deps via apt/yum/dnf
#  - Safe JSON writing using jq (preferred) or python3 fallback
#
# NOTE: Filename kept as requested. Project name is "shadowsocks-rust".

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
RELEASE_TAG="latest"      # or e.g. v1.17.1
INSTALL_DIR=""
OPEN_PUBLIC="false"
UFW_ENABLE="true"
ALLOW_IPS=()
USERS=()                  # entries "name:password"
SINGLE_PASSWORD=""
DRY_RUN="false"

# New flags
AUTO_INSTALL_DEPS="false" # off by default (GitHub-friendly); enable with --install-deps
INSTALL_JQ="auto"         # auto|true|false  (auto = try install if --install-deps)

# ---------- helpers ----------
log()  { echo -e "[+] $*"; }
warn() { echo -e "[!] $*" >&2; }
die()  { echo -e "[x] $*" >&2; exit 1; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Please run as root (e.g., sudo ./${SCRIPT_NAME} ...)"
  fi
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run] $*"
  else
    eval "$@"
  fi
}

usage() {
  cat <<'EOF'
Usage:
  sudo ./install-shadowsrocks-rust.sh --port 12345 [options]

Required:
  --port <PORT>                 Listening port (e.g., 12345)

User/Auth (choose ONE style):
  --password <PASS>             Single user password
  --user <NAME:PASS>            Multi-user entry (repeatable)

Crypto / Transport:
  --method <METHOD>             Default: chacha20-ietf-poly1305
  --mode <tcp_only|tcp_and_udp> Default: tcp_only
  --timeout <SECONDS>           Default: 300

Release selection:
  --tag <TAG|latest>            Default: latest (from GitHub releases)

Firewall (UFW):
  --allow-ip <IP|CIDR>          Allow only these sources to connect to the SS port (repeatable)
  --open-public                 Open the SS port to the public (NOT recommended)
  --no-ufw-enable               Do not enable/reload UFW (still writes rules if UFW is active)

Dependencies / JSON:
  --install-deps                Auto-install required deps via apt/dnf/yum
  --no-install-deps             Do not auto-install deps (default)
  --install-jq                  When using --install-deps, also install jq (recommended)
  --no-install-jq               When using --install-deps, do NOT install jq (python3 fallback if present)

Other:
  --dry-run                     Print what would be done (no changes)
  -h, --help                    Show this help

Examples:
  sudo ./install-shadowsrocks-rust.sh --port 12345 --password 'STRONGPASS' \
    --allow-ip 1.1.1.1 --allow-ip 2.2.2.2 --mode tcp_only

  sudo ./install-shadowsrocks-rust.sh --port 12345 --method chacha20-ietf-poly1305 \
    --user A1:'PASS_A1' --user A2:'PASS_A2' --mode tcp_and_udp \
    --allow-ip 1.1.1.1 --allow-ip 2.2.2.2 \
    --install-deps --install-jq
EOF
}

# Parse CLI
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) PORT="${2:-}"; shift 2;;
    --method) METHOD="${2:-}"; shift 2;;
    --mode) MODE="${2:-}"; shift 2;;
    --timeout) TIMEOUT="${2:-}"; shift 2;;
    --tag) RELEASE_TAG="${2:-}"; shift 2;;
    --allow-ip) ALLOW_IPS+=("${2:-}"); shift 2;;
    --user) USERS+=("${2:-}"); shift 2;;
    --password) SINGLE_PASSWORD="${2:-}"; shift 2;;
    --open-public) OPEN_PUBLIC="true"; shift 1;;
    --no-ufw-enable) UFW_ENABLE="false"; shift 1;;
    --install-deps) AUTO_INSTALL_DEPS="true"; shift 1;;
    --no-install-deps) AUTO_INSTALL_DEPS="false"; shift 1;;
    --install-jq) INSTALL_JQ="true"; shift 1;;
    --no-install-jq) INSTALL_JQ="false"; shift 1;;
    --dry-run) DRY_RUN="true"; shift 1;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1 (use --help)";;
  esac
done

validate_inputs() {
  [[ -n "$PORT" ]] || die "--port is required"
  [[ "$PORT" =~ ^[0-9]+$ ]] || die "--port must be a number"
  (( PORT >= 1 && PORT <= 65535 )) || die "--port must be in 1..65535"

  case "$MODE" in
    tcp_only|tcp_and_udp) ;;
    *) die "--mode must be tcp_only or tcp_and_udp" ;;
  esac

  [[ "$TIMEOUT" =~ ^[0-9]+$ ]] || die "--timeout must be a number"

  if [[ -n "$SINGLE_PASSWORD" && ${#USERS[@]} -gt 0 ]]; then
    die "Use either --password OR --user ... (not both)"
  fi
  if [[ -z "$SINGLE_PASSWORD" && ${#USERS[@]} -eq 0 ]]; then
    die "You must provide either --password or at least one --user NAME:PASS"
  fi
  if [[ "$OPEN_PUBLIC" == "true" && ${#ALLOW_IPS[@]} -gt 0 ]]; then
    die "Use either --open-public OR --allow-ip ... (not both)"
  fi

  if [[ ${#USERS[@]} -gt 0 ]]; then
    for up in "${USERS[@]}"; do
      [[ "$up" == *:* ]] || die "--user must be in NAME:PASS format (got: $up)"
      local name="${up%%:*}"
      local pass="${up#*:}"
      [[ -n "$name" ]] || die "--user NAME cannot be empty"
      [[ -n "$pass" ]] || die "--user PASS cannot be empty for $name"
    done
  fi
}

detect_pkg_mgr() {
  if has_cmd apt-get; then echo "apt"
  elif has_cmd dnf; then echo "dnf"
  elif has_cmd yum; then echo "yum"
  else echo "none"
  fi
}

install_deps() {
  [[ "$AUTO_INSTALL_DEPS" == "true" ]] || return 0

  local pm
  pm="$(detect_pkg_mgr)"
  [[ "$pm" != "none" ]] || die "No supported package manager found (apt/dnf/yum). Install deps manually."

  log "Auto-installing dependencies using: $pm"

  if [[ "$pm" == "apt" ]]; then
    run "apt-get update -y"
    # curl tar xz for .tar.xz extraction; ca-certificates for TLS downloads
    run "apt-get install -y curl tar xz-utils ca-certificates"
    # python3 used as jq fallback for JSON-safe generation
    run "apt-get install -y python3"
    if [[ "$INSTALL_JQ" == "true" || "$INSTALL_JQ" == "auto" ]]; then
      run "apt-get install -y jq"
    fi
  else
    local installer="$pm"
    # For yum, ensure EPEL isn't required for jq; we attempt anyway.
    run "$installer -y install curl tar xz ca-certificates"
    # python3 often present, but try to ensure it
    run "$installer -y install python3 || true"
    if [[ "$INSTALL_JQ" == "true" || "$INSTALL_JQ" == "auto" ]]; then
      run "$installer -y install jq || true"
    fi
  fi
}

ensure_min_deps_present() {
  # After optional auto-install, enforce required commands exist
  has_cmd curl || die "curl is required (install it or use --install-deps)"
  has_cmd tar  || die "tar is required (install it or use --install-deps)"
  # xz not always a cmd name, but tar -xJ needs xz support; ensure xz exists
  has_cmd xz   || warn "xz not found; extracting .tar.xz may fail. Install xz/xz-utils or use --install-deps."
}

detect_platform() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) echo "x86_64-unknown-linux-gnu" ;;
    aarch64|arm64) echo "aarch64-unknown-linux-gnu" ;;
    *) die "Unsupported architecture: $arch. Install manually from shadowsocks-rust releases." ;;
  esac
}

get_latest_tag() {
  local api="https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest"
  local tag
  tag="$(curl -fsSL "$api" | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  [[ -n "$tag" ]] || die "Failed to detect latest release tag from GitHub"
  echo "$tag"
}

download_and_install_ssserver() {
  local triple tag url tmp
  triple="$(detect_platform)"
  tag="$RELEASE_TAG"
  [[ "$tag" != "latest" ]] || tag="$(get_latest_tag)"

  local base1="shadowsocks-${tag}.${triple}.tar.xz"
  local base2="shadowsocks-${tag#v}.${triple}.tar.xz"
  local url1="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${tag}/${base1}"
  local url2="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${tag}/${base2}"

  tmp="$(mktemp -d)"
  INSTALL_DIR="$tmp"

  log "Downloading shadowsocks-rust ssserver (${tag}, ${triple})"
  if curl -fL --retry 3 --retry-delay 1 -o "${tmp}/pkg.tar.xz" "$url1" >/dev/null 2>&1; then
    url="$url1"
  elif curl -fL --retry 3 --retry-delay 1 -o "${tmp}/pkg.tar.xz" "$url2" >/dev/null 2>&1; then
    url="$url2"
  else
    die "Failed to download release asset. Tried:
  - $url1
  - $url2"
  fi

  log "Downloaded: $url"
  run "tar -C '$tmp' -xJf '$tmp/pkg.tar.xz'"

  local found
  found="$(find "$tmp" -type f -name ssserver -perm -u+x | head -n1 || true)"
  [[ -n "$found" ]] || die "Could not find ssserver binary in the extracted package"

  run "install -m 0755 '$found' '$BIN_PATH'"
  log "Installed ssserver to $BIN_PATH"
}

create_user_and_dirs() {
  if ! id -u "$SS_USER" >/dev/null 2>&1; then
    log "Creating system user: $SS_USER"
    run "useradd --system --no-create-home --shell /usr/sbin/nologin '$SS_USER'"
  fi

  run "mkdir -p '$CONF_DIR' '$STATE_DIR' '$LOG_DIR'"
  run "chown -R '$SS_USER':'$SS_GROUP' '$STATE_DIR' '$LOG_DIR' || true"
  run "chmod 0755 '$CONF_DIR'"
  run "chmod 0700 '$STATE_DIR'"
}

# ---- JSON safe writer ----
write_config_json_safe() {
  log "Writing config to $CONF_PATH (JSON-safe)"

  run "mkdir -p '$CONF_DIR'"

  if has_cmd jq; then
    log "Using jq to generate JSON"
    if [[ -n "$SINGLE_PASSWORD" ]]; then
      # Single-user config
      run "jq -n \
        --arg server '0.0.0.0' \
        --argjson port ${PORT} \
        --arg method '${METHOD}' \
        --arg mode '${MODE}' \
        --argjson timeout ${TIMEOUT} \
        --arg password '${SINGLE_PASSWORD}' \
        '{
          server: \$server,
          server_port: \$port,
          method: \$method,
          mode: \$mode,
          timeout: \$timeout,
          password: \$password,
          log: { level: \"warn\" }
        }' > '${CONF_PATH}'"
    else
      # Multi-user config
      # Build users JSON array using jq
      local jq_users='[]'
      for up in "${USERS[@]}"; do
        local name="${up%%:*}"
        local pass="${up#*:}"
        jq_users="$(jq -cn --argjson arr "$jq_users" --arg n "$name" --arg p "$pass" '$arr + [{name:$n,password:$p}]')"
      done

      # Write final config
      run "jq -n \
        --arg server '0.0.0.0' \
        --argjson port ${PORT} \
        --arg method '${METHOD}' \
        --arg mode '${MODE}' \
        --argjson timeout ${TIMEOUT} \
        --argjson users '${jq_users}' \
        '{
          server: \$server,
          server_port: \$port,
          method: \$method,
          mode: \$mode,
          timeout: \$timeout,
          users: \$users,
          log: { level: \"warn\" }
        }' > '${CONF_PATH}'"
    fi

    run "chmod 0644 '${CONF_PATH}'"
    return 0
  fi

  if has_cmd python3; then
    log "jq not found; using python3 to generate JSON"
    # Feed variables via environment to avoid shell escaping pain
    # USERS and ALLOW_IPS aren't written into config; only USERS auth list.
    local py_script
    py_script="$(mktemp)"
    cat > "$py_script" <<'PY'
import json, os, sys

port = int(os.environ["SS_PORT"])
method = os.environ["SS_METHOD"]
mode = os.environ["SS_MODE"]
timeout = int(os.environ["SS_TIMEOUT"])

single_password = os.environ.get("SS_SINGLE_PASSWORD", "")
users_raw = os.environ.get("SS_USERS", "")

cfg = {
  "server": "0.0.0.0",
  "server_port": port,
  "method": method,
  "mode": mode,
  "timeout": timeout,
  "log": {"level": "warn"},
}

if single_password:
  cfg["password"] = single_password
else:
  users = []
  # users_raw format: name\0pass\nname\0pass...
  for line in users_raw.splitlines():
    if not line:
      continue
    try:
      name, pw = line.split("\0", 1)
    except ValueError:
      raise SystemExit(f"Bad SS_USERS line: {line!r}")
    users.append({"name": name, "password": pw})
  cfg["users"] = users

out_path = os.environ["SS_CONF_PATH"]
with open(out_path, "w", encoding="utf-8") as f:
  json.dump(cfg, f, ensure_ascii=False, indent=2)
  f.write("\n")
PY

    # Encode USERS safely
    local users_blob=""
    if [[ -z "$SINGLE_PASSWORD" ]]; then
      for up in "${USERS[@]}"; do
        local name="${up%%:*}"
        local pass="${up#*:}"
        users_blob+="${name}"$'\0'"${pass}"$'\n'
      done
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
      echo "[dry-run] python3 JSON generation to ${CONF_PATH}"
      rm -f "$py_script"
      return 0
    fi

    SS_PORT="$PORT" SS_METHOD="$METHOD" SS_MODE="$MODE" SS_TIMEOUT="$TIMEOUT" \
    SS_SINGLE_PASSWORD="$SINGLE_PASSWORD" SS_USERS="$users_blob" SS_CONF_PATH="$CONF_PATH" \
      python3 "$py_script"

    rm -f "$py_script"
    chmod 0644 "$CONF_PATH"
    return 0
  fi

  warn "Neither jq nor python3 found. Falling back to a minimal JSON writer (passwords must NOT contain quotes/backslashes/newlines)."
  write_config_json_unsafe_fallback
}

write_config_json_unsafe_fallback() {
  local tmpconf
  tmpconf="$(mktemp)"

  {
    echo "{"
    echo "  \"server\": \"0.0.0.0\","
    echo "  \"server_port\": ${PORT},"
    echo "  \"method\": \"${METHOD}\","
    echo "  \"mode\": \"${MODE}\","
    echo "  \"timeout\": ${TIMEOUT},"
    if [[ -n "$SINGLE_PASSWORD" ]]; then
      echo "  \"password\": \"${SINGLE_PASSWORD}\","
    else
      echo "  \"users\": ["
      local i=0
      for up in "${USERS[@]}"; do
        local name="${up%%:*}"
        local pass="${up#*:}"
        i=$((i+1))
        if [[ $i -lt ${#USERS[@]} ]]; then
          echo "    { \"name\": \"${name}\", \"password\": \"${pass}\" },"
        else
          echo "    { \"name\": \"${name}\", \"password\": \"${pass}\" }"
        fi
      done
      echo "  ],"
    fi
    echo "  \"log\": {"
    echo "    \"level\": \"warn\""
    echo "  }"
    echo "}"
  } > "$tmpconf"

  run "install -m 0644 '$tmpconf' '$CONF_PATH'"
  run "rm -f '$tmpconf'"
}

write_systemd_unit() {
  log "Writing systemd unit to $UNIT_PATH"

  local unit_tmp
  unit_tmp="$(mktemp)"

  cat > "$unit_tmp" <<EOF
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
ReadWritePaths=${STATE_DIR} ${LOG_DIR} ${CONF_DIR}
AmbientCapabilities=
CapabilityBoundingSet=
LockPersonality=true
MemoryDenyWriteExecute=true
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true

[Install]
WantedBy=multi-user.target
EOF

  run "install -m 0644 '$unit_tmp' '$UNIT_PATH'"
  run "rm -f '$unit_tmp'"

  run "systemctl daemon-reload"
  run "systemctl enable --now ssserver"
}

configure_ufw() {
  if ! has_cmd ufw; then
    warn "ufw not found; skipping firewall configuration."
    return 0
  fi

  log "Configuring UFW for port ${PORT}"
  run "ufw allow 22/tcp >/dev/null || true"

  if [[ "$OPEN_PUBLIC" == "true" ]]; then
    log "Opening port ${PORT} to public (as requested)"
    run "ufw allow ${PORT}/tcp >/dev/null || true"
    if [[ "$MODE" == "tcp_and_udp" ]]; then
      run "ufw allow ${PORT}/udp >/dev/null || true"
    fi
  else
    if [[ ${#ALLOW_IPS[@]} -eq 0 ]]; then
      warn "No --allow-ip provided and --open-public not set."
      warn "For safety, port ${PORT} will NOT be opened to the public automatically."
      warn "If you intended to allow specific A nodes, rerun with --allow-ip A1_IP --allow-ip A2_IP ..."
    else
      for ip in "${ALLOW_IPS[@]}"; do
        run "ufw allow from ${ip} to any port ${PORT} proto tcp >/dev/null || true"
        if [[ "$MODE" == "tcp_and_udp" ]]; then
          run "ufw allow from ${ip} to any port ${PORT} proto udp >/dev/null || true"
        fi
      done
      run "ufw deny ${PORT} >/dev/null || true"
    fi
  fi

  if [[ "$UFW_ENABLE" == "true" ]]; then
    if ufw status | grep -qi "inactive"; then
      log "Enabling UFW"
      run "ufw --force enable >/dev/null"
    else
      run "ufw reload >/dev/null || true"
    fi
  else
    log "Skipping UFW enable/reload (--no-ufw-enable)"
  fi
}

print_summary() {
  echo
  log "Done."
  echo "  ssserver binary : ${BIN_PATH}"
  echo "  config file     : ${CONF_PATH}"
  echo "  systemd unit    : ssserver (enabled)"
  echo "  listening port  : ${PORT}"
  echo "  method          : ${METHOD}"
  echo "  mode            : ${MODE}"
  if [[ -n "$SINGLE_PASSWORD" ]]; then
    echo "  auth            : single password"
  else
    echo "  auth            : multi-user (${#USERS[@]} users)"
  fi
  echo
  echo "Useful commands:"
  echo "  systemctl status ssserver --no-pager"
  echo "  journalctl -u ssserver -f"
  echo "  ss -lntup | grep ${PORT} || true"
  if has_cmd ufw; then
    echo
    echo "Firewall:"
    echo "  ufw status numbered"
  fi
}

cleanup() {
  if [[ -n "${INSTALL_DIR:-}" && -d "${INSTALL_DIR:-}" ]]; then
    rm -rf "${INSTALL_DIR}" || true
  fi
}
trap cleanup EXIT

main() {
  need_root
  validate_inputs

  # Optional auto-install deps
  install_deps
  ensure_min_deps_present

  log "Starting installation (dry-run=${DRY_RUN})"
  download_and_install_ssserver
  create_user_and_dirs
  write_config_json_safe
  write_systemd_unit
  configure_ufw
  print_summary
}

main
