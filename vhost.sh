#!/bin/bash
####################################################################
# locklet — vhost / SSL 管理脚本 (oneinstack 风格)
#
# 用法 (交互):     ./vhost.sh            [主菜单]
# 用法 (命令行):
#   ./vhost.sh add -d example.com [-d www.example.com] [选项]
#   ./vhost.sh list
#   ./vhost.sh del -d example.com [--purge-webroot] [--purge-ssl]
#   ./vhost.sh ssl -d example.com --ssl <le|le-staging|zerossl|custom|wildcard> [选项]
#   ./vhost.sh wildcard -d example.com --dns <provider> [选项]
#       (通配符证书: 签发 <主域名> + *.<主域名>, DNS-01 验证, 自动续期)
#
# 通用选项:
#   -d, --domain <domain>       域名 (可多次; 第一个为主域名)
#   -w, --webroot <dir>         网站根目录 (默认 /data/wwwroot/<主域名>)
#       --rewrite <name>        伪静态: none|wordpress|typecho|laravel
#       --accesslog <y|n>       访问日志 (默认 n)
#       --hotlink <y|n>         防盗链 (默认 n)
#       --ssl <mode>            le | le-staging | zerossl | custom | wildcard | none
#                               wildcard = 复用已申请的通配符证书 (--use-wildcard 指定)
#       --use-wildcard <name>   使用哪个通配符证书 (证书目录名, 默认 auto 自动匹配)
#       --email <addr>          ACME 账户邮箱
#       --zerossl-key <key>     ZeroSSL API key (自动获取 EAB)
#       --eab-kid/--eab-hmac    手动指定 EAB (ZeroSSL)
#       --cert/--key <path>     自定义证书 (custom 模式)
#       --dns <provider>        DNS 服务商 (wildcard 用): cloudflare|aliyun|dnspod|
#                               tencentcloud|godaddy|manual(测试)|其他(lego dnshelp)
#       --dns-resolvers <ns>    DNS 查询用 resolver (可多次, 如 8.8.8.8:53)
#       --force-https <y|n>     http 强制跳转 https (默认 y)
#       --ca-url <url>          覆盖 ACME 目录地址 (自建 CA/step-ca/pebble 测试用)
#       --tls-skip-verify       跳过 CA TLS 校验 (自建 ACME 测试用)
#       --yes                   跳过所有确认
####################################################################
set -u

LOCKLET_ROOT="$(cd "$(dirname "$0")" && pwd)"
. "$LOCKLET_ROOT/include/common.sh"
. "$LOCKLET_ROOT/include/check_os.sh"
. "$LOCKLET_ROOT/include/vhost_render.sh"
. "$LOCKLET_ROOT/include/vhost_acme.sh"
load_options "$LOCKLET_ROOT/options.conf"

NGINX_SBIN="$nginx_prefix/sbin/nginx"
VHOST_DIR="$nginx_prefix/conf/vhost"
SSL_ROOT="$nginx_prefix/conf/ssl"
REWRITE_DIR="$nginx_prefix/conf/rewrite"
LEGO_BIN="/usr/local/bin/lego"

# CA 目录地址
CA_LE="https://acme-v02.api.letsencrypt.org/directory"
CA_LE_STAGING="https://acme-staging-v02.api.letsencrypt.org/directory"
CA_ZEROSSL="https://acme.zerossl.com/v2/DV90"

ACTION=""
DOMAINS_ARR=()
DNS_RESOLVERS_ARR=()
ASSUME_YES=0
TLS_SKIP=0

usage() { sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

need_val() {
  [ "$1" -ge 2 ] || log_fatal "参数 $2 缺少值 (见 --help)"
}

[ $# -eq 0 ] && ACTION="menu"

while [ $# -gt 0 ]; do
  case "$1" in
    add|list|del|ssl|wildcard) ACTION="$1" ;;
    -d|--domain)      need_val $# "$1"; DOMAINS_ARR+=("$2"); shift ;;
    -w|--webroot)     need_val $# "$1"; opt_webroot="$2"; shift ;;
    --rewrite)        need_val $# "$1"; opt_rewrite="$2"; shift ;;
    --accesslog)      need_val $# "$1"; opt_accesslog="$2"; shift ;;
    --hotlink)        need_val $# "$1"; opt_hotlink="$2"; shift ;;
    --ssl)            need_val $# "$1"; opt_ssl="$2"; shift ;;
    --use-wildcard)   need_val $# "$1"; opt_use_wildcard="$2"; shift ;;
    --email)          need_val $# "$1"; opt_email="$2"; shift ;;
    --zerossl-key)    need_val $# "$1"; opt_zerossl_key="$2"; shift ;;
    --eab-kid)        need_val $# "$1"; opt_eab_kid="$2"; shift ;;
    --eab-hmac)       need_val $# "$1"; opt_eab_hmac="$2"; shift ;;
    --cert)           need_val $# "$1"; opt_cert="$2"; shift ;;
    --key)            need_val $# "$1"; opt_key="$2"; shift ;;
    --dns)            need_val $# "$1"; opt_dns="$2"; shift ;;
    --dns-resolvers)  need_val $# "$1"; DNS_RESOLVERS_ARR+=("$2"); shift ;;
    --force-https)    need_val $# "$1"; opt_force_https="$2"; shift ;;
    --ca-url)         need_val $# "$1"; opt_ca_url="$2"; shift ;;
    --tls-skip-verify) TLS_SKIP=1 ;;
    --yes|-y)         ASSUME_YES=1 ;;
    --purge-webroot)  opt_purge_webroot=y ;;
    --purge-ssl)      opt_purge_ssl=y ;;
    -h|--help)        usage ;;
    *) log_fatal "未知参数: $1 (见 --help)" ;;
  esac
  shift
done

# ---------------- 前置检查 ----------------
check_root
[ -x "$NGINX_SBIN" ] || log_fatal "nginx 未安装 ($NGINX_SBIN), 请先运行 ./install.sh"
[ -d "$VHOST_DIR" ]  || mkdir -p "$VHOST_DIR"

# 菜单循环前重置单次操作状态
reset_action_state() {
  DOMAINS_ARR=()
  DNS_RESOLVERS_ARR=()
  unset opt_webroot opt_rewrite opt_accesslog opt_hotlink opt_ssl opt_use_wildcard \
        opt_email opt_zerossl_key opt_eab_kid opt_eab_hmac opt_cert opt_key \
        opt_dns opt_force_https opt_ca_url opt_purge_webroot opt_purge_ssl
  MAIN="" SERVER_NAMES="" WEBROOT="" REWRITE="" ACCESSLOG="" HOTLINK=""
  SSL_MODE="" FORCE_HTTPS="" EMAIL="" CA_SERVER="" EAB_KID="" EAB_HMAC=""
  DNS_PROVIDER="" DNS_CRED_FILE="" DNS_RESOLVERS_STR="" SSL_DIR="" SSL_CRT="" SSL_KEY="" WC_MAIN=""
}

# 若未通过 -d 传入域名, 在交互模式下提示输入
prompt_domain_if_empty() { # $1 提示语
  local prompt="$1" d=""
  if [ ${#DOMAINS_ARR[@]} -ge 1 ]; then
    return 0
  fi
  if [ "$ASSUME_YES" -eq 1 ]; then
    log_fatal "缺少 -d 域名"
  fi
  while :; do
    read -r -p "$(printf '\033[32m%s\033[0m' "$prompt")" d
    if [ -n "$d" ] && valid_domain "$d"; then
      DOMAINS_ARR+=("$d")
      return 0
    fi
    log_warn "域名格式不正确 (不支持通配符): $d"
  done
}

# ---------------- SSL 子流程 ----------------
do_ssl_wildcard_use() { # 复用通配符证书上线 https (无需重新签发)
  pick_wildcard_cert "$MAIN"
  log_info "使用通配符证书: $WC_MAIN ($SSL_CRT)"
  render_ssl_vhost
  echo
  log_info "证书详情 (来自 $WC_MAIN):"
  printf '      CA     : \033[33m%s\033[0m\n' "$(ca_friendly_name "$SSL_CRT")"
  cert_summary "$SSL_CRT" | sed 's/^/      /'
  log_info "续期由 $WC_MAIN 的 renew.env 负责 (本 vhost 不单独续期)"
}

do_ssl_issue() { # le | le-staging | zerossl (需先有 http vhost)
  resolve_acme_account

  # DNS 指向检查 (http-01 必需): 官方 prod CA 才校验, staging/自建 CA 跳过
  if { [ "$SSL_MODE" = "le" ] || [ "$SSL_MODE" = "zerossl" ]; } && [ -z "${opt_ca_url:-}" ]; then
    if ! dns_check "$MAIN"; then
      log_warn "域名 $MAIN 未解析到本机, http-01 验证大概率失败!"
      if [ "$ASSUME_YES" -eq 0 ]; then
        confirm "仍然继续?" n || log_fatal "已取消"
      else
        log_warn "继续尝试签发..."
      fi
    fi
  fi

  SSL_DIR="$SSL_ROOT/$MAIN"
  mkdir -p "$SSL_DIR"

  if ! run_lego_issue; then
    log_error "证书签发失败 (CA: $CA_SERVER)"
    log_info  "可先回退到 http 站点; 排查后重试: ./vhost.sh ssl -d $MAIN --ssl $SSL_MODE"
    return 1
  fi

  SSL_CRT="$SSL_DIR/certificates/$MAIN.crt"
  SSL_KEY="$SSL_DIR/certificates/$MAIN.key"
  [ -f "$SSL_CRT" ] && [ -f "$SSL_KEY" ] || { log_error "证书文件缺失"; return 1; }

  write_renew_env "$SSL_DIR" "${DOMAINS_ARR[*]}" "$EMAIL" "$CA_SERVER" "$WEBROOT"

  render_ssl_vhost
  echo
  log_info "证书详情 ($MAIN):"
  printf '      CA     : \033[33m%s\033[0m\n' "$(ca_friendly_name "$SSL_CRT")"
  cert_summary "$SSL_CRT" | sed 's/^/      /'
}

do_ssl_custom() {
  SSL_CRT="${opt_cert:-}"; SSL_KEY="${opt_key:-}"
  if [ "$ASSUME_YES" -eq 0 ]; then
    while [ ! -f "$SSL_CRT" ]; do
      read -r -p "$(printf '\033[32m%s\033[0m' '证书 crt 路径: ')" SSL_CRT
      [ -f "$SSL_CRT" ] || log_warn "文件不存在"
    done
    while [ ! -f "$SSL_KEY" ]; do
      read -r -p "$(printf '\033[32m%s\033[0m' '私钥 key 路径: ')" SSL_KEY
      [ -f "$SSL_KEY" ] || log_warn "文件不存在"
    done
  fi
  [ -f "$SSL_CRT" ] && [ -f "$SSL_KEY" ] || log_fatal "证书/私钥文件不存在: $SSL_CRT / $SSL_KEY"
  render_ssl_vhost
  log_info "证书详情 ($MAIN):"
  printf '      CA     : \033[33m%s\033[0m\n' "$(ca_friendly_name "$SSL_CRT")"
  cert_summary "$SSL_CRT" | sed 's/^/      /'
}

# ---------------- 动作: wildcard ----------------
do_wildcard() { # ./vhost.sh wildcard -d example.com --dns cloudflare ...
  prompt_domain_if_empty '请输入主域名 (如 example.com, 将自动覆盖 *.example.com): '
  # 主域名取第一个非通配符域名
  MAIN=""
  local d
  for d in "${DOMAINS_ARR[@]}"; do
    case "$d" in \*.*) ;; *) MAIN="$d"; break ;; esac
  done
  [ -n "$MAIN" ] || log_fatal "请用非通配符域名作为主域名, 如: -d example.com (自动覆盖 *.example.com)"
  valid_domain "$MAIN" || log_fatal "主域名格式不正确: $MAIN"

  # 域名集合: 主域名 + *.主域名
  DOMAINS_ARR=("$MAIN" "*.$MAIN")
  SERVER_NAMES="$MAIN *.$MAIN"

  SSL_MODE="${opt_ssl:-le}"
  case "$SSL_MODE" in
    le|le-staging|zerossl) ;;
    *) log_fatal "通配符证书 CA 仅支持: le | le-staging | zerossl" ;;
  esac

  resolve_acme_account
  dns_provider_prompt

  SSL_DIR="$SSL_ROOT/$MAIN"
  mkdir -p "$SSL_DIR"
  dns_provider_collect "$SSL_DIR"
  DNS_CRED_FILE="$SSL_DIR/dns.env"
  # shellcheck disable=SC1090
  [ -f "$DNS_CRED_FILE" ] && . "$DNS_CRED_FILE"

  DNS_RESOLVERS_STR="${DNS_RESOLVERS_ARR[*]:-}"
  if ! run_lego_dns_issue; then
    log_error "通配符证书签发失败 (CA: $CA_SERVER, DNS: $DNS_PROVIDER)"
    log_info  "常见原因: DNS 凭证错误 / TXT 记录未生效 / provider 名称不对 (lego dnshelp 查询)"
    return 1
  fi

  local crt="$SSL_DIR/certificates/$MAIN.crt"
  local key="$SSL_DIR/certificates/$MAIN.key"
  [ -f "$crt" ] && [ -f "$key" ] || { log_error "证书文件缺失"; return 1; }

  write_renew_env "$SSL_DIR" "${DOMAINS_ARR[*]}" "$EMAIL" "$CA_SERVER" ""

  echo
  log_info "通配符证书签发成功 ($SSL_DIR):"
  printf '      CA     : \033[33m%s\033[0m\n' "$(ca_friendly_name "$crt")"
  printf '      SANs   : %s\n' "$(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null | grep -o 'DNS:[^ ,]*' | tr '\n' ' ')"
  cert_summary "$crt" | sed 's/^/      /'
  echo
  log_info "续期: 已加入 lego-renew.timer (DNS 凭证: $DNS_CRED_FILE)"
  log_info "使用: ./vhost.sh add -d <子域名> --ssl wildcard"
}

# ---------------- 动作: add ----------------
ask_common_questions() {
  # 域名
  prompt_domain_if_empty '请输入域名 (如 www.example.com): '
  MAIN="${DOMAINS_ARR[0]}"
  local d
  for d in "${DOMAINS_ARR[@]}"; do
    valid_domain "$d" || log_fatal "域名格式不正确: $d"
  done
  SERVER_NAMES="${DOMAINS_ARR[*]}"

  # 交互补充额外域名
  if [ ${#DOMAINS_ARR[@]} -eq 1 ] && [ "$ASSUME_YES" -eq 0 ]; then
    read -r -p "$(printf '\033[32m%s\033[0m' '额外域名 (逗号分隔, 含 www 别名; 回车跳过): ')" more
    IFS=',' read -ra extra <<< "${more// /}"
    for d in "${extra[@]:-}"; do
      [ -n "$d" ] && valid_domain "$d" && DOMAINS_ARR+=("$d")
    done
    SERVER_NAMES="${DOMAINS_ARR[*]}"
  fi

  # webroot
  WEBROOT="${opt_webroot:-}"
  if [ -z "$WEBROOT" ]; then
    if [ "$ASSUME_YES" -eq 1 ]; then
      WEBROOT="$wwwroot_dir/$MAIN"
    else
      read -r -p "$(printf '\033[32m%s\033[0m' "网站目录 [默认: $wwwroot_dir/$MAIN]: ")" w
      WEBROOT="${w:-$wwwroot_dir/$MAIN}"
    fi
  fi

  # 伪静态
  REWRITE="${opt_rewrite:-}"
  if [ -z "$REWRITE" ] && [ "$ASSUME_YES" -eq 1 ]; then
    REWRITE="none"
  fi
  while [ -z "$REWRITE" ] || ! [ -f "$LOCKLET_ROOT/config/rewrite/$REWRITE.conf" ]; do
    if [ "$ASSUME_YES" -eq 1 ]; then
      log_fatal "未知伪静态模板: $REWRITE"
    fi
    [ -n "$REWRITE" ] && log_warn "未知伪静态模板: $REWRITE"
    printf "\033[33m%s\033[0m\n" "伪静态规则:"
    echo "  1 none   2 wordpress   3 typecho   4 laravel"
    read -r -p "选择 [默认 1]: " r
    case "${r:-1}" in
      1) REWRITE=none ;;
      2) REWRITE=wordpress ;;
      3) REWRITE=typecho ;;
      4) REWRITE=laravel ;;
      *) REWRITE="" ;;
    esac
  done

  # 访问日志
  if [ -z "${opt_accesslog:-}" ]; then
    if [ "$ASSUME_YES" -eq 1 ]; then
      opt_accesslog=n
    else
      confirm "记录访问日志?" n && opt_accesslog=y || opt_accesslog=n
    fi
  fi
  ACCESSLOG="$opt_accesslog"

  # 防盗链
  if [ -z "${opt_hotlink:-}" ]; then
    if [ "$ASSUME_YES" -eq 1 ]; then
      opt_hotlink=n
    else
      confirm "开启防盗链?" n && opt_hotlink=y || opt_hotlink=n
    fi
  fi
  HOTLINK="$opt_hotlink"

  # SSL
  SSL_MODE="${opt_ssl:-}"
  if [ -z "$SSL_MODE" ] && [ "$ASSUME_YES" -eq 1 ]; then
    SSL_MODE="none"
  fi
  while [ -z "$SSL_MODE" ]; do
    printf "\033[33m%s\033[0m\n" "SSL 证书:"
    cat <<EOF
  1. Let's Encrypt (正式)
  2. Let's Encrypt (staging 测试)
  3. ZeroSSL (ACME, 需要 API key 或 EAB)
  4. 自有证书 (自定义 crt/key 路径)
  5. 暂不启用 SSL
  6. 复用已有通配符证书 (*.域名)
EOF
    read -r -p "选择 [默认 1]: " s
    case "${s:-1}" in
      1) SSL_MODE=le ;;
      2) SSL_MODE=le-staging ;;
      3) SSL_MODE=zerossl ;;
      4) SSL_MODE=custom ;;
      5) SSL_MODE=none ;;
      6) SSL_MODE=wildcard ;;
    esac
  done

  # force https
  if [ "$SSL_MODE" != "none" ]; then
    if [ -z "${opt_force_https:-}" ]; then
      if [ "$ASSUME_YES" -eq 1 ]; then
        opt_force_https=y
      else
        confirm "强制 https (301)?" y && opt_force_https=y || opt_force_https=n
      fi
    fi
    FORCE_HTTPS="${opt_force_https:-y}"
  fi
}

do_add() {
  ask_common_questions

  local out="$VHOST_DIR/$MAIN.conf"
  [ -f "$out" ] && log_fatal "vhost 已存在: $out (如需更换 SSL 请用: ./vhost.sh ssl -d $MAIN)"

  mkdir -p "$WEBROOT"
  [ -f "$WEBROOT/index.html" ] || printf '<h1>%s</h1>\n<p>locklet default page</p>\n' "$MAIN" > "$WEBROOT/index.html"
  chown -R "${www_user}:${www_group}" "$WEBROOT"
  write_rewrite_conf "$MAIN" "$REWRITE"

  # 第一步: 先落 http vhost (acme http-01 需要它)
  emit_vhost http > "$out"
  if ! nginx_apply; then
    rm -f "$out"; nginx_reload_only
    log_fatal "vhost 配置校验失败, 已回滚"
  fi
  step_ok "http vhost 已上线: $out"

  # 第二步: SSL
  case "$SSL_MODE" in
    none) ;;
    le|le-staging|zerossl) do_ssl_issue ;;
    custom) do_ssl_custom ;;
    wildcard) do_ssl_wildcard_use ;;
    *) log_fatal "未知 ssl 模式: $SSL_MODE" ;;
  esac

  echo
  if [ "$SSL_MODE" = "none" ]; then
    log_info "站点添加完成: http://$MAIN"
  else
    log_info "站点添加完成: https://$MAIN"
  fi
}

# ---------------- 动作: ssl (已有站点补 ssl) ----------------
do_ssl() {
  prompt_domain_if_empty '请输入要配置 SSL 的站点主域名: '
  MAIN="${DOMAINS_ARR[0]}"
  local out="$VHOST_DIR/$MAIN.conf"
  [ -f "$out" ] || log_fatal "vhost 不存在: $out (请先 ./vhost.sh add)"

  # 从现有 conf 提取参数 (精确匹配 server 级 access_log, 避免被静态块 access_log off 误判)
  SERVER_NAMES=$(grep -m1 'server_name' "$out" | sed 's/.*server_name //;s/;.*//')
  WEBROOT=$(grep -m1 '^\s*root' "$out" | sed 's/.*root //;s/;.*//')
  [ -z "$WEBROOT" ] && { WEBROOT="${opt_webroot:-$wwwroot_dir/$MAIN}"; log_warn "conf 未找到 root, 使用 $WEBROOT"; }
  [ -n "${opt_webroot:-}" ] && WEBROOT="$opt_webroot"

  if [ -n "${opt_accesslog:-}" ]; then
    ACCESSLOG="$opt_accesslog"
  elif grep -qE '^[[:space:]]{4}access_log[[:space:]]+/' "$out"; then
    ACCESSLOG="y"
  else
    ACCESSLOG="n"
  fi

  if [ -n "${opt_hotlink:-}" ]; then
    HOTLINK="$opt_hotlink"
  elif grep -q 'valid_referers' "$out"; then
    HOTLINK="y"
  else
    HOTLINK="n"
  fi

  REWRITE="none"
  [ -f "$REWRITE_DIR/$MAIN.conf" ] && REWRITE="keep"
  # 通配符域名不能走 http-01, 从 SAN 列表剔除
  set -f
  # shellcheck disable=SC2207
  DOMAINS_ARR=($(printf '%s\n' $SERVER_NAMES | grep -v '^\*\.' || true))
  set +f
  [ ${#DOMAINS_ARR[@]} -ge 1 ] || DOMAINS_ARR=("$MAIN")

  SSL_MODE="${opt_ssl:-}"
  if [ -z "$SSL_MODE" ]; then
    if [ "$ASSUME_YES" -eq 1 ]; then
      SSL_MODE="le"
    else
      printf "\033[33m%s\033[0m\n" "选择证书方式:"
      cat <<EOF
  1. Let's Encrypt (正式)
  2. Let's Encrypt (staging 测试)
  3. ZeroSSL (ACME)
  4. 自有证书
  5. 复用已有通配符证书
EOF
      read -r -p "选择 [默认 1]: " s
      case "${s:-1}" in
        1) SSL_MODE=le ;; 2) SSL_MODE=le-staging ;; 3) SSL_MODE=zerossl ;; 4) SSL_MODE=custom ;; 5) SSL_MODE=wildcard ;;
      esac
    fi
  fi

  if [ -z "${opt_force_https:-}" ]; then
    if [ "$ASSUME_YES" -eq 1 ]; then
      opt_force_https=y
    else
      confirm "强制 https (301)?" y && opt_force_https=y || opt_force_https=n
    fi
  fi
  FORCE_HTTPS="${opt_force_https:-y}"

  case "$SSL_MODE" in
    le|le-staging|zerossl) do_ssl_issue ;;
    custom) do_ssl_custom ;;
    wildcard) do_ssl_wildcard_use ;;
    *) log_fatal "未知 ssl 模式: $SSL_MODE" ;;
  esac
}

# ---------------- 动作: list ----------------
do_list() {
  local conf found=0
  printf "\n\033[36m%-32s %-4s %-28s %s\033[0m\n" "DOMAIN" "SSL" "WEBROOT" "CERT"
  printf '%s\n' "--------------------------------------------------------------------------------"
  for conf in "$VHOST_DIR"/*.conf; do
    [ -f "$conf" ] || continue
    found=1
    local names ssl="✗" webroot crt="-"
    names=$(grep -m1 'server_name' "$conf" | sed 's/.*server_name //;s/;.*//')
    webroot=$(grep -m1 '^\s*root' "$conf" | sed 's/.*root //;s/;.*//' | head -1)
    local crt_line
    crt_line=$(grep -m1 '^\s*ssl_certificate ' "$conf" | sed 's/.*ssl_certificate //;s/;.*//')
    if [ -n "$crt_line" ] && [ -f "$crt_line" ]; then
      ssl="✔"
      local ca enddate
      ca=$(ca_friendly_name "$crt_line")
      enddate=$(openssl x509 -in "$crt_line" -noout -enddate 2>/dev/null | cut -d= -f2 | cut -d' ' -f1-3)
      crt="$ca -> $enddate"
    elif [ -n "$crt_line" ]; then
      crt="文件缺失: $crt_line"
    fi
    printf "%-32s %-4s %-28s %s\n" "${names:-$(basename "$conf")}" "$ssl" "${webroot:-?}" "$crt"
  done
  [ "$found" -eq 0 ] && log_warn "暂无 vhost, 使用 ./vhost.sh add 添加"

  # 通配符证书区
  local wc
  wc=$(find_wildcard_certs)
  if [ -n "$wc" ]; then
    echo
    printf "\033[36m%-32s %s\033[0m\n" "WILDCARD CERT" "SANs / CA / 到期"
    printf '%s\n' "--------------------------------------------------------------------------------"
    local m sans wcdir wcrt
    while IFS='|' read -r m sans; do
      [ -n "$m" ] || continue
      wcdir="$SSL_ROOT/$m"
      wcrt=$(ls "$wcdir/certificates/"*.crt 2>/dev/null | grep -v '\.issuer\.' | head -1)
      [ -n "$wcrt" ] || continue
      local ca enddate
      ca=$(ca_friendly_name "$wcrt")
      enddate=$(openssl x509 -in "$wcrt" -noout -enddate 2>/dev/null | cut -d= -f2 | cut -d' ' -f1-3)
      printf "%-32s %s | %s -> %s\n" "*.$m" "$(echo "$sans" | sed 's/DNS://g')" "$ca" "$enddate"
      if [ ! -f "$wcdir/renew.env" ]; then
        printf "%-32s %s\n" "" "(⚠ 无 renew.env, 不会自动续期)"
      fi
    done <<< "$wc"
  fi
  echo
}

# ---------------- 动作: del ----------------
do_del() {
  prompt_domain_if_empty '请输入要删除的站点主域名: '
  MAIN="${DOMAINS_ARR[0]}"
  local out="$VHOST_DIR/$MAIN.conf"
  [ -f "$out" ] || log_fatal "vhost 不存在: $out"

  echo
  grep -E 'server_name|root ' "$out" | sed 's/^ *//' | head -5
  echo
  local webroot crt_line
  webroot=$(grep -m1 '^\s*root' "$out" | sed 's/.*root //;s/;.*//')
  crt_line=$(grep -m1 '^\s*ssl_certificate ' "$out" 2>/dev/null | sed 's/.*ssl_certificate //;s/;.*//')

  if [ "$ASSUME_YES" -ne 1 ]; then
    confirm "确认删除 vhost: $MAIN ?" n || return 0
  fi

  rm -f "$out" "$REWRITE_DIR/$MAIN.conf"

  if [ "${opt_purge_webroot:-n}" != "y" ] && [ "$ASSUME_YES" -eq 0 ]; then
    confirm "同时删除网站目录 (${webroot:-未知})?" n && opt_purge_webroot=y
  fi
  if [ "${opt_purge_webroot:-n}" = "y" ] && [ -n "$webroot" ] && [ "$webroot" != "$wwwroot_dir/default" ] && [ -d "$webroot" ]; then
    rm -rf "${webroot:?}"
    step_ok "已删除目录: $webroot"
  fi

  # ssl 证书: 引用他处(如共享通配符)证书目录的 vhost 不动证书
  if [ -n "$crt_line" ] && [ -f "$crt_line" ]; then
    case "$crt_line" in
      "$SSL_ROOT/$MAIN/"*) : ;;               # 自有证书目录
      *)
        if [[ "$crt_line" == "$SSL_ROOT"/* ]]; then
          step_ok "共享证书保留: $crt_line (通配符证书由其主域名管理)"
          nginx_reload_only
          step_ok "vhost 已删除: $MAIN"
          return 0
        fi
        ;;
    esac
  fi

  local purge_ssl="${opt_purge_ssl:-n}"
  if [ -d "$SSL_ROOT/$MAIN" ] && [ "$purge_ssl" != "y" ] && [ "$ASSUME_YES" -eq 0 ]; then
    confirm "同时删除证书目录 $SSL_ROOT/$MAIN (含续期配置)?" n && purge_ssl=y
  fi
  if [ -d "$SSL_ROOT/$MAIN" ] && [ "$purge_ssl" = "y" ]; then
    rm -rf "${SSL_ROOT:?}/$MAIN"
    step_ok "已删除证书: $SSL_ROOT/$MAIN"
  fi

  nginx_reload_only
  step_ok "vhost 已删除: $MAIN"
}

# ---------------- 主菜单 ----------------
menu() {
  while :; do
    clear
    printf "\033[32m"
    cat <<'EOF'
+--------------------------------------------------+
|          locklet vhost 管理工具                   |
+--------------------------------------------------+
EOF
    printf "\033[0m\n"
    cat <<EOF
  1. 添加站点
  2. 站点列表
  3. 删除站点
  4. 给已有站点配置 SSL 证书
  5. 申请通配符证书 (*.域名, DNS-01)
  6. 退出
EOF
    read -r -p "$(printf '\033[32m%s\033[0m' '请输入选择 [1-6]: ')" choice
    reset_action_state
    case "$choice" in
      1) do_add ;;
      2) do_list ;;
      3) do_del ;;
      4) do_ssl ;;
      5) do_wildcard ;;
      6) exit 0 ;;
      *) log_warn "无效选择" ;;
    esac
    echo
    read -r -p "按回车返回菜单..." _t
  done
}

case "$ACTION" in
  add)      do_add ;;
  list)     do_list ;;
  del)      do_del ;;
  ssl)      do_ssl ;;
  wildcard) do_wildcard ;;
  menu)     menu ;;
  *)        usage ;;
esac
