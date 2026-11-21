#!/bin/bash
# locklet ACME / DNS-01 / 通配符证书工具库

# ---------------- DNS / EAB / ACME 账户 ----------------
dns_check() { # $1 domain; 0=解析到本机
  local d="$1" resolved ip r
  resolved=$(getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' | sort -u)
  [ -z "$resolved" ] && return 1
  for r in $resolved; do
    for ip in $(get_local_ips); do
      [ "$r" = "$ip" ] && return 0
    done
  done
  return 1
}

fetch_zerossl_eab() { # $1 access_key -> 设置 EAB_KID / EAB_HMAC
  local resp
  resp=$(curl -sS --max-time 30 "https://api.zerossl.com/acme/eab?access_key=$1") || return 1
  if command -v jq >/dev/null 2>&1; then
    EAB_KID=$(printf '%s' "$resp" | jq -r '.eab_kid // .EABKID // empty' 2>/dev/null)
    EAB_HMAC=$(printf '%s' "$resp" | jq -r '.eab_hmac_key // .EABHMACKey // empty' 2>/dev/null)
  else
    EAB_KID=$(printf '%s' "$resp" | sed -n 's/.*"EABKID"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    EAB_HMAC=$(printf '%s' "$resp" | sed -n 's/.*"EABHMACKey"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  fi
  [ -n "$EAB_KID" ] && [ -n "$EAB_HMAC" ]
}

# 统一解析 Email / CA 目录 / ZeroSSL EAB (供 HTTP-01 与 DNS-01 共用)
resolve_acme_account() {
  EMAIL="${opt_email:-${default_email:-}}"
  while [ -z "$EMAIL" ] || ! valid_email "$EMAIL"; do
    if [ "$ASSUME_YES" -eq 1 ]; then
      log_fatal "缺少有效 ACME 邮箱: 请通过 --email 或 options.conf 的 default_email 指定"
    fi
    [ -n "$EMAIL" ] && log_warn "邮箱格式不正确"
    read -r -p "$(printf '\033[32mACME 账户邮箱 (如 admin@%s): \033[0m' "$MAIN")" EMAIL
  done

  EAB_KID="${opt_eab_kid:-}"
  EAB_HMAC="${opt_eab_hmac:-}"
  case "$SSL_MODE" in
    le)         CA_SERVER="$CA_LE" ;;
    le-staging) CA_SERVER="$CA_LE_STAGING" ;;
    zerossl)
      CA_SERVER="$CA_ZEROSSL"
      if [ -z "$EAB_KID" ] && [ -n "${opt_zerossl_key:-}" ]; then
        log_info "通过 ZeroSSL API 获取 EAB 凭证..."
        fetch_zerossl_eab "$opt_zerossl_key" || log_fatal "获取 EAB 失败, 请检查 API key"
        step_ok "EAB 获取成功 (kid: ${EAB_KID:0:8}...)"
      fi
      if [ -z "$EAB_KID" ] && [ "$ASSUME_YES" -eq 0 ]; then
        while [ -z "$EAB_KID" ]; do
          printf "\033[33m%s\033[0m\n" "ZeroSSL 需要 EAB (External Account Binding):"
          echo "  1. 输入 ZeroSSL API access key 自动获取"
          echo "  2. 手动输入 eab kid / hmac"
          read -r -p "选择 [默认 1]: " z
          case "${z:-1}" in
            1)
              read -r -p "ZeroSSL API access key: " zkey
              fetch_zerossl_eab "$zkey" && step_ok "EAB 获取成功" || log_warn "获取失败"
              ;;
            2)
              read -r -p "eab kid: " EAB_KID
              read -r -p "eab hmac: " EAB_HMAC
              ;;
          esac
        done
      fi
      if [ -z "$EAB_KID" ] || [ -z "$EAB_HMAC" ]; then
        log_fatal "ZeroSSL 需要 EAB: --zerossl-key <key> 或 --eab-kid/--eab-hmac"
      fi
      ;;
    *) log_fatal "不支持的 ACME CA 模式: $SSL_MODE" ;;
  esac

  if [ -n "${opt_ca_url:-}" ]; then
    CA_SERVER="$opt_ca_url"
    log_info "使用自定义 ACME 目录: $CA_SERVER"
  fi
}

write_renew_env() { # $1 ssl_dir $2 domains_str $3 email $4 server $5 webroot
  chmod 700 "$1"
  cat > "$1/renew.env" <<EOF
# locklet 自动生成 (lego 续期参数)
DOMAINS="$2"
EMAIL="$3"
SERVER="$4"
WEBROOT="$5"
EAB_KID="${EAB_KID:-}"
EAB_HMAC="${EAB_HMAC:-}"
TLS_SKIP_VERIFY=${TLS_SKIP}
DNS_PROVIDER="${DNS_PROVIDER:-}"
DNS_CRED_FILE="${DNS_CRED_FILE:-}"
DNS_RESOLVERS="${DNS_RESOLVERS_STR:-}"
EOF
  chmod 600 "$1/renew.env"
}

run_lego_issue() { # 变量: DOMAINS_ARR EMAIL CA_SERVER SSL_DIR WEBROOT EAB_KID EAB_HMAC TLS_SKIP
  # 注意: lego v5 的参数跟在子命令 run 之后 (v4 是全局参数在前)
  local args=(--server "$CA_SERVER" --email "$EMAIL" --path "$SSL_DIR"
              --http --http.webroot "$WEBROOT" --accept-tos)
  local d
  for d in "${DOMAINS_ARR[@]}"; do
    args+=(--domains "$d")
  done
  if [ -n "${EAB_KID:-}" ]; then
    args+=(--eab --eab.kid "$EAB_KID" --eab.hmac "$EAB_HMAC")
  fi
  [ "$TLS_SKIP" = "1" ] && args+=(--tls-skip-verify)

  log_info "lego 签发: ${DOMAINS_ARR[*]}"
  "$LEGO_BIN" run "${args[@]}" --deploy-hook "/bin/systemctl reload nginx"
}

# ---------------- 通配符证书 (DNS-01) ----------------
# provider -> 需要的环境变量 (lego 官方 provider 见: lego dnshelp)
dns_provider_envs() { # $1 provider -> stdout: 空格分隔的环境变量名
  case "$1" in
    cloudflare)     echo "CLOUDFLARE_DNS_API_TOKEN" ;;
    aliyun)         echo "ALICLOUD_ACCESS_KEY ALICLOUD_SECRET_KEY" ;;
    dnspod)         echo "DNSPOD_API_KEY" ;;
    tencentcloud)   echo "TENCENTCLOUD_SECRET_ID TENCENTCLOUD_SECRET_KEY" ;;
    godaddy)        echo "GODADDY_API_KEY GODADDY_API_SECRET" ;;
    *)              echo "" ;;
  esac
}

dns_provider_prompt() { # 交互选择 -> DNS_PROVIDER
  DNS_PROVIDER="${opt_dns:-}"
  if [ -z "$DNS_PROVIDER" ] && [ "$ASSUME_YES" -eq 1 ]; then
    log_fatal "缺少 DNS 服务商: 请使用 --dns <provider>"
  fi
  while [ -z "$DNS_PROVIDER" ]; do
    printf "\033[33m%s\033[0m\n" "DNS 服务商 (用于 DNS-01 验证):"
    cat <<EOF
  1. cloudflare     2. aliyun 阿里云
  3. dnspod 腾讯云 DNSPod   4. tencentcloud 腾讯云 API
  5. godaddy        6. 其他 (完整列表: lego dnshelp)
  7. manual 手动添加 TXT (测试/无 API)
EOF
    read -r -p "选择 [默认 1]: " p
    case "${p:-1}" in
      1) DNS_PROVIDER=cloudflare ;;
      2) DNS_PROVIDER=aliyun ;;
      3) DNS_PROVIDER=dnspod ;;
      4) DNS_PROVIDER=tencentcloud ;;
      5) DNS_PROVIDER=godaddy ;;
      6)
        read -r -p "provider 名称 (如 namedotcom, 见 lego dnshelp): " DNS_PROVIDER
        "$LEGO_BIN" dnshelp 2>/dev/null | grep -q "\"$DNS_PROVIDER\"" \
          || { log_warn "$DNS_PROVIDER 不是合法的 lego provider"; DNS_PROVIDER=""; }
        ;;
      7) DNS_PROVIDER=manual ;;
    esac
  done
}

dns_provider_collect() { # $1 ssl_dir : 收集凭证写入 dns.env (chmod 600)
  local vars var val line key
  if [ "$DNS_PROVIDER" = "manual" ]; then
    log_warn "manual 模式: 签发/续期时会提示手动创建 TXT 记录 (仅适合测试, 无法无人值守续期)"
    return 0
  fi
  chmod 700 "$1"
  : > "$1/dns.env"
  vars=$(dns_provider_envs "$DNS_PROVIDER")
  if [ -z "$vars" ]; then
    # 未知 provider: 自由输入 KEY=VALUE 行
    printf "\033[33m%s\033[0m\n" "输入 $DNS_PROVIDER 的凭证 (格式 KEY=VALUE, 每行一个, 空行结束):"
    while IFS= read -r line; do
      [ -z "$line" ] && break
      key="${line%%=*}"
      val="${line#*=}"
      printf 'export %s=%q\n' "$key" "$val" >> "$1/dns.env"
    done
  else
    for var in $vars; do
      val="${!var:-}"
      if [ -n "$val" ]; then
        # 已在环境变量中提供 (无人值守: CLOUDFLARE_DNS_API_TOKEN=xxx ./vhost.sh wildcard ...)
        printf 'export %s=%q\n' "$var" "$val" >> "$1/dns.env"
        continue
      fi
      if [ "$ASSUME_YES" = "1" ]; then
        log_fatal "缺少 DNS 凭证: 请先 export $var 或使用交互模式"
      fi
      val=""
      while [ -z "$val" ]; do
        read -r -p "$(printf '\033[32m%s: \033[0m' "$var")" val
      done
      printf 'export %s=%q\n' "$var" "$val" >> "$1/dns.env"
    done
  fi
  chmod 600 "$1/dns.env"
  step_ok "DNS 凭证已保存: $1/dns.env (600)"
}

run_lego_dns_issue() { # 变量: DOMAINS_ARR EMAIL CA_SERVER SSL_DIR DNS_PROVIDER EAB_KID EAB_HMAC TLS_SKIP DNS_RESOLVERS_ARR
  local args=(--server "$CA_SERVER" --email "$EMAIL" --path "$SSL_DIR"
              --accept-tos --dns "$DNS_PROVIDER")
  local d r
  for d in "${DOMAINS_ARR[@]}"; do
    args+=(--domains "$d")
  done
  if [ -n "${EAB_KID:-}" ]; then
    args+=(--eab --eab.kid "$EAB_KID" --eab.hmac "$EAB_HMAC")
  fi
  [ "$TLS_SKIP" = "1" ] && args+=(--tls-skip-verify)
  for r in ${DNS_RESOLVERS_ARR[@]+"${DNS_RESOLVERS_ARR[@]}"}; do
    args+=(--dns.resolvers "$r")
  done
  if [ "$DNS_PROVIDER" = "manual" ]; then
    # manual: 跳过 TXT 传播检查(本地测试), stdin 自动应答回车
    args+=(--dns.propagation.wait 1s)
    yes "" | "$LEGO_BIN" run "${args[@]}" --deploy-hook "/bin/systemctl reload nginx"
  else
    "$LEGO_BIN" run "${args[@]}" --deploy-hook "/bin/systemctl reload nginx"
  fi
}

# ---- 已有通配符证书的查找 / 匹配 / 复用 ----
find_wildcard_certs() { # 输出 "main|SAN 列表" 行
  local d crt sans
  for d in "$SSL_ROOT"/*/; do
    [ -d "$d" ] || continue
    crt=$(ls "$d/certificates/"*.crt 2>/dev/null | grep -v '\.issuer\.' | head -1)
    [ -n "$crt" ] || continue
    sans=$(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null | grep -o 'DNS:[^ ,]*' | tr '\n' ' ')
    echo "$sans" | grep -q 'DNS:\*\.' || continue
    echo "$(basename "$d")|$sans"
  done
}

wc_covers() { # $1=SAN 列表, $2=域名; 通配符 SAN 是否覆盖域名
  local s base label matched=1
  set -f
  for s in $1; do
    s=${s#DNS:}
    case "$s" in
      \*.*) base=${s#\*.}; label=${2%."$base"} ;;
      *)    [ "$s" = "$2" ] && { matched=0; break; }; continue ;;
    esac
    # 仅覆盖一层子域名: *.example.com 匹配 a.example.com, 不匹配 a.b.example.com
    if [ "${label}" != "$2" ] && [ "$label" = "${2%."$base"}" ] && ! [[ "$label" == *.* ]]; then
      matched=0
      break
    fi
  done
  set +f
  return "$matched"
}

pick_wildcard_cert() { # $1 目标域名; 设置 WC_MAIN SSL_CRT SSL_KEY
  local target="$1" all cover=() c m sans pick
  all=$(find_wildcard_certs)
  [ -z "$all" ] && log_fatal "暂无已申请的通配符证书, 请先: ./vhost.sh wildcard -d <主域名> --dns <provider>"

  while IFS='|' read -r m sans; do
    [ -n "$m" ] || continue
    wc_covers "$sans" "$target" && cover+=("$m|$sans")
  done <<< "$all"

  pick="${opt_use_wildcard:-auto}"
  if [ "$pick" = "auto" ]; then
    case ${#cover[@]} in
      0)
        log_error "没有覆盖 $target 的通配符证书"
        log_info  "现有通配符证书: $(echo "$all" | cut -d'|' -f1 | tr '\n' ' ')"
        log_fatal "可先申请: ./vhost.sh wildcard -d <主域名> --dns <provider>"
        ;;
      1) WC_MAIN="${cover[0]%%|*}" ;;
      *)
        if [ "$ASSUME_YES" -eq 1 ]; then
          log_fatal "多个通配符证书覆盖 $target, 请用 --use-wildcard 指定: $(printf '%s ' "${cover[@]%%|*}")"
        fi
        printf "\033[33m%s\033[0m\n" "选择要使用的通配符证书:"
        local i=1
        for c in "${cover[@]}"; do
          echo "  $i. ${c%%|*}  (${c#*|})"
          i=$((i+1))
        done
        read -r -p "选择 [1]: " n
        n="${n:-1}"
        WC_MAIN="${cover[$((n-1))]%%|*}"
        ;;
    esac
  else
    WC_MAIN="$pick"
    local ok=0
    for c in "${cover[@]:-}"; do
      [ "${c%%|*}" = "$WC_MAIN" ] && ok=1
    done
    [ "$ok" = "1" ] || log_fatal "通配符证书 '$WC_MAIN' 不存在或不覆盖 $target (覆盖列表: $(printf '%s ' "${cover[@]%%|*}"))"
  fi

  local crt key
  crt=$(ls "$SSL_ROOT/$WC_MAIN/certificates/"*.crt 2>/dev/null | grep -v '\.issuer\.' | head -1)
  key="$SSL_ROOT/$WC_MAIN/certificates/$WC_MAIN.key"
  [ -f "$key" ] || key=$(ls "$SSL_ROOT/$WC_MAIN/certificates/"*.key 2>/dev/null | head -1)
  [ -n "$crt" ] && [ -f "$key" ] || log_fatal "通配符证书文件缺失: $SSL_ROOT/$WC_MAIN/certificates/"
  SSL_CRT="$crt"; SSL_KEY="$key"
}
