#!/bin/bash
# locklet 公共函数库 (oneinstack 风格输出)
# shellcheck disable=SC2034

# ---------------- 颜色与日志 ----------------
red='\033[31m'; green='\033[32m'; yellow='\033[33m'; plain='\033[0m'

log_info()    { printf "\033[32m[ INFO  ]\033[0m %s\n" "$*"; }
log_warn()    { printf "\033[33m[ WARN  ]\033[0m %s\n" "$*"; }
log_error()   { printf "\033[31m[ ERROR ]\033[0m %s\n" "$*"; }
log_fatal()   { log_error "$@"; exit 1; }

step_ok()     { printf " \033[32m✔\033[0m %s\n" "$*"; }
step_fail()   { printf " \033[31m✘\033[0m %s\n" "$*"; }

wait_apt()    { printf "\033[33m...\033[0m %s\n" "$*"; }

confirm() { # confirm "提示" [default_y|default_n]
  local prompt="$1" def="${2:-y}" ans
  if [ "$def" = "y" ]; then
    read -r -p "$(printf '\033[32m%s\033[0m \033[33m[y/N]\033[0m' "$prompt [default: y]: ")" ans || ans=""
  else
    read -r -p "$(printf '\033[32m%s\033[0m \033[33m[y/N]\033[0m' "$prompt [default: n]: ")" ans || ans=""
  fi
  ans="${ans:-$def}"
  [[ "$ans" =~ ^[Yy] ]]
}

# ---------------- 工具函数 ----------------
# 读取 options.conf
load_options() {
  local conf="${1:-$(dirname "$0")/../options.conf}"
  [ -f "$conf" ] || log_fatal "$conf not found"
  # shellcheck disable=SC1090
  . "$conf"
  nginx_version="${nginx_version:-1.31.9}"
  pcre2_version="${pcre2_version:-10.49}"
  zlib_version="${zlib_version:-1.4}"
  openssl_version="${openssl_version:-3.5.4}"
  lego_version="${lego_version:-5.6.0}"
  headers_more_version="${headers_more_version:-0.42}"
  nginx_prefix="${nginx_prefix:-/usr/local/nginx}"
  wwwroot_dir="${wwwroot_dir:-/data/wwwroot}"
  wwwlogs_dir="${wwwlogs_dir:-/data/wwwlogs}"
  www_user="${www_user:-www}"
  www_group="${www_group:-www}"
  nginx_modules="${nginx_modules:-}"
  github_mirror="${github_mirror:-}"
  nginx_cc_opt="${nginx_cc_opt:--O2 -fstack-protector-strong -Wformat -Werror=format-security -D_FORTIFY_SOURCE=2 -fPIC}"
  nginx_ld_opt="${nginx_ld_opt:--Wl,-z,relro -Wl,-z,now -Wl,--as-needed -pie}"
  install_mode="${install_mode:-deb}"
  nginx_channel="${nginx_channel:-stable}"
  auto_upgrade="${auto_upgrade:-y}"
  # 路径变量: deb 模式由 install.sh 回写为官方布局; source 模式按 oneinstack 布局
  nginx_prefix="${nginx_prefix:-/usr/local/nginx}"
  nginx_sbin="${nginx_sbin:-$nginx_prefix/sbin/nginx}"
  nginx_conf="${nginx_conf:-$nginx_prefix/conf}"
  nginx_vhost_dir="${nginx_vhost_dir:-$nginx_conf/vhost}"
  nginx_ssl_dir="${nginx_ssl_dir:-$nginx_conf/ssl}"
  nginx_rewrite_dir="${nginx_rewrite_dir:-$nginx_conf/rewrite}"
  locklet_dir="${locklet_dir:-}"
}

# set_opt <file> <key> <value>: 回写 options.conf (不存在则追加)
set_opt() {
  local file="$1" key="$2" val="$3"
  touch "$file"
  if grep -q "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$file"
  else
    echo "${key}=${val}" >> "$file"
  fi
}

# 创建 www 运行账户 (deb/source 模式共用)
create_www_user() {
  if id -g "$www_group" >/dev/null 2>&1; then
    log_info "用户组 $www_group 已存在"
  else
    groupadd "$www_group"
    step_ok "创建用户组 $www_group"
  fi
  if id -u "$www_user" >/dev/null 2>&1; then
    log_info "用户 $www_user 已存在"
  else
    useradd -g "$www_group" -s /usr/sbin/nologin -M "$www_user"
    step_ok "创建用户 $www_user (组 $www_group, nologin)"
  fi
}

# 准备数据目录 (路径变量按安装模式指向 /etc/nginx 或 /usr/local/nginx/conf)
prepare_dirs() {
  mkdir -p "$wwwroot_dir/default" "$wwwlogs_dir" \
           "$nginx_vhost_dir" "$nginx_ssl_dir" "$nginx_rewrite_dir"
  chown -R "${www_user}:${www_group}" "$wwwroot_dir" "$wwwlogs_dir"
  chmod -R 755 "$wwwroot_dir"
  step_ok "创建目录: $wwwroot_dir $wwwlogs_dir $nginx_vhost_dir"
}

# 获取本机所有 IPv4
get_local_ips() {
  local ips=""
  if command -v ip >/dev/null 2>&1; then
    ips=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
  fi
  [ -z "$ips" ] && ips=$(hostname -I 2>/dev/null || echo "")
  echo "$ips"
}

# 校验域名字符
valid_domain() {
  [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]]
}

valid_email() {
  [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

# 友好显示证书颁发机构
ca_friendly_name() { # $1: crt file
  local issuer o
  issuer=$(openssl x509 -in "$1" -noout -issuer 2>/dev/null)
  if echo "$issuer" | grep -qi "let's encrypt"; then echo "Let's Encrypt"
  elif echo "$issuer" | grep -qi "zerossl"; then echo "ZeroSSL"
  elif echo "$issuer" | grep -qi "pebble"; then echo "Pebble (test CA)"
  elif echo "$issuer" | grep -qi "google trust"; then echo "Google Trust Services"
  else
    o=$(echo "$issuer" | sed -n 's/.*O *= *\([^,]*\).*/\1/p' | head -1)
    [ -z "$o" ] && o=$(echo "$issuer" | sed -n 's/.*CN *= *\([^,]*\).*/\1/p' | head -1)
    echo "${o:-self-signed/unknown}"
  fi
}

cert_summary() { # $1: crt file -> 多行: CA / subject / 有效期
  local crt="$1"
  [ -f "$crt" ] || { echo "N/A"; return; }
  local issuer subj enddate
  issuer=$(openssl x509 -in "$crt" -noout -issuer 2>/dev/null | sed 's/^issuer=//')
  subj=$(openssl x509 -in "$crt" -noout -subject 2>/dev/null | sed 's/^subject=//')
  enddate=$(openssl x509 -in "$crt" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')
  printf '      Issuer : %s\n      Subject: %s\n      Expires: %s\n' "$issuer" "$subj" "$enddate"
}
