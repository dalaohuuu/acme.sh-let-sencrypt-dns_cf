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
example：
三个参数：
|项目|值|说明|
|:---|:-------------------------|:-------------------------|
|Zone|domain.com|根域名（自动识别，不必输入）|
|Domain|example.domain.com|完整域名|
|CF_token|1234567890abcdef|具有编辑 Cloudflare 域名权限的 API Token|
|renewtime|300| 脚本检查 IP 更新周期（秒）|

## 运行脚本：
sudo apt update && sudo apt install -y curl && \
curl -fsSL https://raw.githubusercontent.com/dalaohuuu/vps_tools/main/cloudflare-ddns.sh -o cloudflare-ddns.sh && \
chmod +x cloudflare-ddns.sh && \
sudo ./cloudflare-ddns.sh install example.domain.com 1234567890abcdef 300