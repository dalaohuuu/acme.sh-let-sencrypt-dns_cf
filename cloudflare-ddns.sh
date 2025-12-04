#!/usr/bin/env bash
#
# Cloudflare DDNS Script (Smart Zone Detection + systemd installer)
#
# 前台运行：
#   ./cloudflare-ddns.sh <full_hostname> <api_token> [interval]
# 示例：
#   ./cloudflare-ddns.sh home.example.com ABCDEF123456 300
#
# 安装为 systemd 服务（推荐）：
#   sudo ./cloudflare-ddns.sh install <full_hostname> <api_token> [interval]
#
# 卸载 systemd 服务：
#   sudo ./cloudflare-ddns.sh uninstall
#
# 仅依赖：curl
#
# Author: dalaohuuu
# License: MIT

set -e

CF_API_BASE="https://api.cloudflare.com/client/v4"

SERVICE_NAME="cloudflare-ddns.service"
ENV_FILE="/etc/cloudflare-ddns.env"
INSTALL_PATH="/usr/local/bin/cloudflare-ddns.sh"

# ------------------ 公共函数：HTTP ------------------
cf_get() {
    local url="$1"
    curl -s -X GET \
        "$url" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json"
}

cf_post() {
    local url="$1"
    local data="$2"
    curl -s -X POST \
        "$url" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        --data "$data"
}

cf_put() {
    local url="$1"
    local data="$2"
    curl -s -X PUT \
        "$url" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        --data "$data"
}

get_public_ip() {
    curl -s https://checkip.amazonaws.com || curl -s https://ipv4.icanhazip.com
}

# --------------- 自动识别 Zone ----------------
find_zone() {
    local full="$1"
    local IFS='.'
    read -r -a labels <<< "$full"
    local n=${#labels[@]}

    # 从最长后缀开始试：a.b.c.example.com → example.com → com
    for ((i=0; i<=n-2; i++)); do
        local candidate=""
        for ((j=i; j<n; j++)); do
            if [[ -z "$candidate" ]]; then
                candidate="${labels[j]}"
            else
                candidate="${candidate}.${labels[j]}"
            fi
        done

        local resp
        resp=$(cf_get "${CF_API_BASE}/zones?name=${candidate}&status=active")

        if echo "$resp" | grep -q '"success":true' && echo "$resp" | grep -q '"id":"'; then
            local zid
            zid=$(echo "$resp" | grep -oP '"id":"\K[^"]+' | head -1)
            if [[ -n "$zid" ]]; then
                ZONE_ID="$zid"
                ZONE_NAME="$candidate"
                return 0
            fi
        fi
    done

    return 1
}

# --------------- 确保 A 记录存在 ----------------
ensure_record() {
    local resp
    resp=$(cf_get "${CF_API_BASE}/zones/${ZONE_ID}/dns_records?type=A&name=${HOST}")

    if echo "$resp" | grep -q '"success":true' && echo "$resp" | grep -q '"id":"'; then
        RECORD_ID=$(echo "$resp" | grep -oP '"id":"\K[^"]+' | head -1)
        return 0
    fi

    echo "No existing A record for ${HOST}, creating one..."
    local ip
    ip=$(get_public_ip | tr -d ' \n\r')

    resp=$(cf_post "${CF_API_BASE}/zones/${ZONE_ID}/dns_records" \
        "{\"type\":\"A\",\"name\":\"${HOST}\",\"content\":\"${ip}\",\"ttl\":1,\"proxied\":false}")

    if echo "$resp" | grep -q '"success":true'; then
        RECORD_ID=$(echo "$resp" | grep -oP '"id":"\K[^"]+' | head -1)
        echo "Created A record for ${HOST} with IP ${ip}"
        return 0
    else
        echo "Error creating DNS record:"
        echo "$resp"
        return 1
    fi
}

update_record() {
    local new_ip="$1"
    cf_put "${CF_API_BASE}/zones/${ZONE_ID}/dns_records/${RECORD_ID}" \
        "{\"type\":\"A\",\"name\":\"${HOST}\",\"content\":\"${new_ip}\",\"ttl\":1,\"proxied\":false}"
}

# ------------------ 前台运行逻辑 ------------------
run_ddns() {
    HOST="$1"
    TOKEN="$2"
    INTERVAL="${3:-300}"

    if [[ -z "$HOST" || -z "$TOKEN" ]]; then
        echo "Usage:"
        echo "  $0 <full_hostname> <api_token> [interval]"
        echo "Example:"
        echo "  $0 home.example.com ABCDEF123456 300"
        exit 1
    fi

    if ! command -v curl >/dev/null 2>&1; then
        echo "Error: curl is required but not installed."
        exit 1
    fi

    CACHE_FILE="/tmp/cf-ddns-${HOST//[^A-Za-z0-9_.-]/_}.ip"

    echo "======================================="
    echo " Cloudflare DDNS (Smart Zone Detection)"
    echo " Hostname : $HOST"
    echo " Interval : $INTERVAL seconds"
    echo "======================================="

    if ! find_zone "$HOST"; then
        echo "Error: Could not detect Cloudflare zone for ${HOST}."
        echo "Make sure the domain is managed by Cloudflare and the API token is correct."
        exit 1
    fi

    echo "Detected Zone: ${ZONE_NAME}"
    echo "Zone ID      : ${ZONE_ID}"

    if ! ensure_record; then
        echo "Error: Unable to create or find A record for ${HOST}."
        exit 1
    fi

    echo "Record ID    : ${RECORD_ID}"
    echo
    echo "DDNS updater started. Press Ctrl + C to stop."
    echo

    while true; do
        NEW_IP=$(get_public_ip | tr -d ' \n\r')
        OLD_IP=""

        [[ -f "$CACHE_FILE" ]] && OLD_IP=$(cat "$CACHE_FILE")

        if [[ -z "$NEW_IP" ]]; then
            echo "$(date '+%F %T') Failed to fetch public IP."
        elif [[ "$NEW_IP" != "$OLD_IP" ]]; then
            echo "$(date '+%F %T') IP changed: ${OLD_IP:-<none>} -> $NEW_IP"
            RESULT=$(update_record "$NEW_IP")

            if echo "$RESULT" | grep -q '"success":true'; then
                echo "$NEW_IP" > "$CACHE_FILE"
                echo "Update successful."
            else
                echo "Update failed:"
                echo "$RESULT"
            fi
        else
            echo "$(date '+%F %T') IP unchanged: $NEW_IP"
        fi

        sleep "$INTERVAL"
    done
}

# ------------------ systemd: 安装 ------------------
install_service() {
    if [[ $EUID -ne 0 ]]; then
        echo "Please run install as root, e.g.: sudo $0 install <hostname> <token> [interval]"
        exit 1
    fi

    HOST="$1"
    TOKEN="$2"
    INTERVAL="${3:-300}"

    if [[ -z "$HOST" || -z "$TOKEN" ]]; then
        echo "Usage:"
        echo "  sudo $0 install <full_hostname> <api_token> [interval]"
        exit 1
    fi

    echo "Installing Cloudflare DDNS as systemd service..."
    echo " Hostname : $HOST"
    echo " Interval : $INTERVAL seconds"
    echo

    # 写 env 文件
    cat >"$ENV_FILE" <<EOF
CF_HOST=${HOST}
CF_TOKEN=${TOKEN}
CF_INTERVAL=${INTERVAL}
EOF

    chmod 600 "$ENV_FILE"

    # 安装脚本到固定路径
    SCRIPT_SRC="$(readlink -f "$0")"
    cp "$SCRIPT_SRC" "$INSTALL_PATH"
    chmod +x "$INSTALL_PATH"

    # 写 systemd unit
    cat >/etc/systemd/system/${SERVICE_NAME} <<EOF
[Unit]
Description=Cloudflare DDNS Updater (Smart Zone Detection)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${ENV_FILE}
ExecStart=${INSTALL_PATH} \${CF_HOST} \${CF_TOKEN} \${CF_INTERVAL}
Restart=always
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now "${SERVICE_NAME}"

    echo "Installed and started ${SERVICE_NAME}."
    echo "View status:  sudo systemctl status ${SERVICE_NAME}"
    echo "View logs:    sudo journalctl -u ${SERVICE_NAME} -f"
}

# ------------------ systemd: 卸载 ------------------
uninstall_service() {
    if [[ $EUID -ne 0 ]]; then
        echo "Please run uninstall as root, e.g.: sudo $0 uninstall"
        exit 1
    fi

    echo "Stopping and disabling ${SERVICE_NAME} (if exists)..."
    systemctl disable --now "${SERVICE_NAME}" 2>/dev/null || true

    echo "Removing unit file and env file (if exists)..."
    rm -f "/etc/systemd/system/${SERVICE_NAME}"
    rm -f "${ENV_FILE}"

    echo "Reloading systemd..."
    systemctl daemon-reload

    echo "Uninstall complete."
}

# ------------------ 入口逻辑 ------------------
CMD="$1"

case "$CMD" in
    install)
        shift
        install_service "$@"
        ;;
    uninstall)
        uninstall_service
        ;;
    *)
        # 保持兼容老用法：
        # ./cloudflare-ddns.sh <host> <token> [interval]
        run_ddns "$@"
        ;;
esac
