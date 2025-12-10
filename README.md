# 1.acme_cf_install.sh
```
curl -fsSL https://raw.githubusercontent.com/dalaohuuu/vps_tools/main/acme_cf_install.sh -o acme_cf_install.sh \
&& chmod +x acme_cf_install.sh \
&& bash acme_cf_install.sh -d 'domain' -t 'cf_token'
```
Usages
Instead domain and cf_token
|参数|值|
|:---|:---:|
|-d|domain|
|-t|cf_token|

# 2.一键检查 Debian 系统信息
```
curl -fsSL https://raw.githubusercontent.com/dalaohuuu/vps_tools/refs/heads/main/debianinfo.sh -o debianinfo.sh \
&& chmod +x debianinfo.sh \
&& bash debianinfo.sh
```
# 3.linux系统ddclient CloudFlare托管域名动态域名解析
```
sudo apt update && sudo apt install -y curl && \
curl -fsSL https://raw.githubusercontent.com/dalaohuuu/vps_tools/main/cloudflare-ddns.sh -o cloudflare-ddns.sh && \
chmod +x cloudflare-ddns.sh && \
sudo ./cloudflare-ddns.sh install YOUR_Domain YOUR_CF_TOKEN renewtime
```
## 3.1 example：
### 3.1.1 参数说明：
|项目|值|说明|
|:---|:-------------------------|:-------------------------|
|Zone|domain.com|根域名（自动识别，不必输入）|
|Domain|example.domain.com|完整域名|
|CF_token|1234567890abcdef|具有编辑 Cloudflare 域名权限的 API Token|
|renewtime|300| 脚本检查 IP 更新周期（秒）|

### 3.1.2 运行脚本：
sudo apt update && sudo apt install -y curl && \
curl -fsSL https://raw.githubusercontent.com/dalaohuuu/vps_tools/main/cloudflare-ddns.sh -o cloudflare-ddns.sh && \
chmod +x cloudflare-ddns.sh && \
sudo ./cloudflare-ddns.sh install example.domain.com 1234567890abcdef 300

# 4.Cloudreve + Nginx + SSL 一键部署脚本

本项目提供一个简洁的自动化脚本，用于在 **纯净 Ubuntu 服务器上部署：**

- **Cloudreve 网盘**
- **Nginx HTTPS 反代（启用自定义端口 8443）**
- **acme.sh 自动申请并安装 Let's Encrypt SSL 证书（Cloudflare DNS）**

脚本默认只反代 Cloudreve，不包含任何 3x-ui 面板或订阅接口内容，适合用作独立网盘站点或为其他程序准备 SSL 环境。

---

## 🚀 功能特点

- 自动安装 Cloudreve（获取 GitHub 最新 release）
- 自动安装 Nginx 并配置反向代理
- 自动使用 acme.sh + Cloudflare DNS 申请证书
- 自动安装证书至：
  - `/root/cert/<domain>/`
  - `/etc/cert/`
- 自动创建 systemd 服务，Cloudreve 开机启动
- 自动配置 HTTPS 访问（端口：`8443`）
- 无 `set -e`，脚本容错性更强

---

## 📦 适用系统

- Ubuntu 20.04 / 22.04 / 24.04 以及其他 Debian 系发行版

---

## 📘 使用方法

### 1. 下载脚本

```bash
curl -fsSL curl -fsSL https://raw.githubusercontent.com/dalaohuuu/vps_tools/refs/heads/main/nginx_proxy.sh -o nginx_proxy.sh \
  && chmod +x nginx_proxy.sh \
  && ./nginx_proxy.sh Domain CF_Token
```