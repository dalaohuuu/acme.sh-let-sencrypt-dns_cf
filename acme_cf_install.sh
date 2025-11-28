#!/bin/bash
set -e
set -o pipefail

# ========================
# 参数默认值（为空时脚本会报错）
DOMAIN=""
CF_TOKEN=""
# ========================

show_help() {
  echo "用法：bash acme_cf_install.sh [参数]"
  echo
  echo "参数："
  echo "  -d DOMAIN       要申请证书的域名"
  echo "  -t CF_TOKEN     Cloudflare API Token"
  echo "  -h              显示帮助"
  echo
  echo "示例："
  echo "  bash acme_cf_install.sh -d example.com -t XXXXXXXXX"
  exit 0
}

# 参数解析
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--domain)
      DOMAIN="$2"
      shift 2
      ;;
    -t|--token)
      CF_TOKEN="$2"
      shift 2
      ;;
    -h|--help)
      show_help
      ;;
    *)
      echo "未知参数: $1"
      show_help
      ;;
  esac
done

# ------------------------
# 参数校验
# ------------------------
if [[ -z "$DOMAIN" ]]; then
  echo "错误：未指定域名，请使用 -d 传入。"
  exit 1
fi

if [[ -z "$CF_TOKEN" ]]; then
  echo "错误：未指定 Cloudflare Token，请使用 -t 传入。"
  exit 1
fi

export CF_Token="$CF_TOKEN"
ACME_ACCOUNT_EMAIL="admin@$DOMAIN"

DIR_ROOT="/root/cert/$DOMAIN"
DIR_ETC="/etc/cert"

echo "=============================="
echo "  acme.sh + Cloudflare 自动申请 SSL"
echo "=============================="
echo
echo "域名: $DOMAIN"
echo "CF Token: 已传入"
echo "路径1: $DIR_ROOT"
echo "路径2: $DIR_ETC"
echo

# 创建目录
mkdir -p "$DIR_ROOT" "$DIR_ETC"

# 检查 acme.sh
if ! command -v acme.sh >/dev/null 2>&1; then
  echo ">>> 未检测到 acme.sh，正在安装..."
  curl https://get.acme.sh | sh -s email="$ACME_ACCOUNT_EMAIL"
fi

# 不管如何，强制把 acme.sh 路径加到 PATH
if [[ -f "$HOME/.acme.sh/acme.sh" ]]; then
  export PATH="$HOME/.acme.sh:$PATH"
fi

# 再检查一次，还是找不到就报错退出
if ! command -v acme.sh >/dev/null 2>&1; then
  echo "错误：acme.sh 已尝试安装，但仍未找到，请检查 ~/.acme.sh 目录。"
  exit 1
fi

# 设置 CA
echo ">>> 设置默认 CA 为 Let's Encrypt..."
acme.sh --set-default-ca --server letsencrypt

echo ">>> 正在申请 SSL 证书..."
acme.sh --issue -d "$DOMAIN" --dns dns_cf --server letsencrypt

echo ">>> 正在安装证书..."
acme.sh --install-cert -d "$DOMAIN" \
  --key-file "$DIR_ROOT/privkey.pem" \
  --fullchain-file "$DIR_ROOT/fullchain.pem"

cp "$DIR_ROOT/privkey.pem" "$DIR_ETC/privkey.pem"
cp "$DIR_ROOT/fullchain.pem" "$DIR_ETC/fullchain.pem"

chmod 600 "$DIR_ROOT/privkey.pem" "$DIR_ETC/privkey.pem"
chmod 644 "$DIR_ROOT/fullchain.pem" "$DIR_ETC/fullchain.pem"

unset CF_Token CF_TOKEN

echo
echo "=============================="
echo "  证书已成功申请并安装完成！"
echo "=============================="
echo "路径："
echo "  /root/cert/$DOMAIN/"
echo "  /etc/cert/"
echo "=============================="
