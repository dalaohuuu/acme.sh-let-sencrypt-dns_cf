#!/usr/bin/env bash
#
# Cloudflare DDNS Script (Smart Zone Detection)
#
# Usage:
#   ./cloudflare-ddns.sh <full_hostname> <api_token> [interval]
#
# Example:
#   ./cloudflare-ddns.sh home.example.com ABCDEF123456 300
#
# - Only curl is required.
# - Zone (root domain) is automatically detected from the hostname.
# - If the A record doesn't exist, it will be created automatically.
#
# Author: dalaohuuu
# License: MIT

set -e

HOST="$1"         # full hostname, e.g. home.example.com
TOKEN="$2"        # Cloudflare API Token
INTERVAL="${3:-300}"

if [[ -z "$HOST" || -z "$TOKEN" ]]; then
    echo "Usage: $0 <full_hostname> <api_token> [interval]"
    echo "Example: $0 home.example.com ABCDEF123456 300"
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "Error: curl is required but not installed."
    exit 1
fi

CACHE_FILE="/tmp/cf-ddns-${HOST//[^A-Za-z0-9_.-]/_}.ip"

CF_API_BASE="https://api.cloudflare.com/client/v4"

# --------------- Helper: HTTP GET ---------------
cf_get() {
    local url="$1"
    curl -s -X GET \
        "$url" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json"
}

# --------------- Helper: HTTP POST ---------------
cf_post() {
    local url="$1"
    local data="$2"
    curl -s -X POST \
        "$url" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        --data "$data"
}

# --------------- Helper: HTTP PUT ---------------
cf_put() {
    local url="$1"
    local data="$2"
    curl -s -X PUT \
        "$url" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        --data "$data"
}

# --------------- Get public IPv4 ---------------
get_public_ip() {
    curl -s https://checkip.amazonaws.com || curl -s https://ipv4.icanhazip.com
}

# --------------- Detect Zone (root domain) from hostname ---------------
find_zone() {
    local full="$1"
    local IFS='.'
    read -r -a labels <<< "$full"
    local n=${#labels[@]}

    # Try from longest suffix: a.b.c.example.com, example.com, etc.
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

# --------------- Ensure DNS A record exists, set RECORD_ID ---------------
ensure_record() {
    local resp
    resp=$(cf_get "${CF_API_BASE}/zones/${ZONE_ID}/dns_records?type=A&name=${HOST}")

    if echo "$resp" | grep -q '"success":true' && echo "$resp" | grep -q '"id":"'; then
        # record exists
        RECORD_ID=$(echo "$resp" | grep -oP '"id":"\K[^"]+' | head -1)
        return 0
    fi

    echo "No existing A record for ${HOST}, creating one..."
    local ip
    ip=$(get_public_ip)

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

# --------------- Update existing A record ---------------
update_record() {
    local new_ip="$1"
    cf_put "${CF_API_BASE}/zones/${ZONE_ID}/dns_records/${RECORD_ID}" \
        "{\"type\":\"A\",\"name\":\"${HOST}\",\"content\":\"${new_ip}\",\"ttl\":1,\"proxied\":false}"
}

echo "======================================="
echo " Cloudflare DDNS (Smart Zone Detection)"
echo " Hostname : $HOST"
echo " Interval : $INTERVAL seconds"
echo "======================================="

# --------------- Detect Zone ---------------
if ! find_zone "$HOST"; then
    echo "Error: Could not detect Cloudflare zone for ${HOST}."
    echo "Make sure the domain is managed by Cloudflare and the API token is correct."
    exit 1
fi

echo "Detected Zone: ${ZONE_NAME}"
echo "Zone ID      : ${ZONE_ID}"

# --------------- Ensure DNS record exists ---------------
if ! ensure_record; then
    echo "Error: Unable to create or find A record for ${HOST}."
    exit 1
fi

echo "Record ID    : ${RECORD_ID}"
echo
echo "DDNS updater started. Press Ctrl + C to stop."
echo

# --------------- Main loop ---------------
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
