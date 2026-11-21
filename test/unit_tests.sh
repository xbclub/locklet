#!/bin/bash
####################################################################
# locklet 本地单元测试 (无需 root / Docker / nginx, macOS & Linux 均可运行)
####################################################################
set -u
cd "$(dirname "$0")/.." || exit 1
LOCKLET_ROOT=$(pwd)

PASS=0; FAIL=0
ok()  { printf " \033[32m✔\033[0m %s\n" "$1"; PASS=$((PASS+1)); }
bad() { printf " \033[31m✘\033[0m %s\n" "$1"; FAIL=$((FAIL+1)); }
section(){ printf "\n\033[36m== %s ==\033[0m\n" "$1"; }

# ---------------- 1. 语法检查 ----------------
section "1. Bash 语法检查 (bash -n)"
for f in install.sh vhost.sh include/*.sh config/lego-renew.sh.tmpl config/locklet-upgrade.sh.tmpl test/*.sh; do
  [ -f "$f" ] || continue
  if bash -n "$f" 2>/dev/null; then
    ok "bash -n $f"
  else
    bad "bash -n 失败: $f"
  fi
done

if command -v shellcheck >/dev/null 2>&1; then
  section "1b. ShellCheck 静态检查"
  if shellcheck -S error install.sh vhost.sh include/*.sh config/lego-renew.sh.tmpl config/locklet-upgrade.sh.tmpl 2>/dev/null; then
    ok "shellcheck (-S error) 通过"
  else
    bad "shellcheck 发现错误"
  fi
fi

# ---------------- 2. --help 输出与参数校验 ----------------
section "2. CLI --help 与缺少参数值校验"
help_v=$(./vhost.sh --help)
if echo "$help_v" | grep -q "locklet — vhost" && ! echo "$help_v" | grep -q "set -u"; then
  ok "vhost.sh --help 输出干净 (无代码泄漏)"
else
  bad "vhost.sh --help 输出异常"
fi

help_i=$(./install.sh --help)
if echo "$help_i" | grep -q "/usr/local/bin/lego" && ! echo "$help_i" | grep -q "set -u"; then
  ok "install.sh --help 输出完整干净"
else
  bad "install.sh --help 输出异常"
fi

err_v=$(./vhost.sh add -d 2>&1)
echo "$err_v" | grep -q "缺少值" && ok "vhost.sh -d 缺值时给出友好错误" || bad "vhost.sh -d 缺值报错异常: $err_v"

err_i=$(./install.sh --nginx-version 2>&1)
echo "$err_i" | grep -q "缺少值" && ok "install.sh --nginx-version 缺值时给出友好错误" || bad "install.sh 缺值报错异常: $err_i"

# ---------------- 3. 公共库函数测试 ----------------
section "3. common.sh / download.sh / nginx.sh 纯函数测试"
# shellcheck disable=SC1091
. "$LOCKLET_ROOT/include/common.sh"
load_options "$LOCKLET_ROOT/options.conf"
# shellcheck disable=SC1091
. "$LOCKLET_ROOT/include/download.sh"
# shellcheck disable=SC1091
. "$LOCKLET_ROOT/include/nginx.sh"
# shellcheck disable=SC1091
. "$LOCKLET_ROOT/include/vhost_render.sh"
# shellcheck disable=SC1091
. "$LOCKLET_ROOT/include/vhost_acme.sh"

valid_domain "example.com"       && ok "valid_domain: example.com"       || bad "valid_domain 误拒 example.com"
valid_domain "a.b.example.com"   && ok "valid_domain: a.b.example.com"   || bad "valid_domain 误拒 a.b.example.com"
! valid_domain "*.example.com"   && ok "valid_domain 拒绝通配符"          || bad "valid_domain 未拒通配符"
! valid_domain "-bad.com"        && ok "valid_domain 拒绝非法前缀"        || bad "valid_domain 未拒 -bad.com"

valid_email "admin@example.com"  && ok "valid_email: admin@example.com"  || bad "valid_email 误拒合法邮箱"
! valid_email "not-an-email"     && ok "valid_email 拒绝非法邮箱"         || bad "valid_email 未拒非法邮箱"

github_mirror="https://mirror.example.com/"
rw=$(url_rewrite "https://github.com/google/ngx_brotli")
[ "$rw" = "https://mirror.example.com/https://github.com/google/ngx_brotli" ] \
  && ok "url_rewrite 正确改写 GitHub URL" || bad "url_rewrite 异常: $rw"
rw_non=$(url_rewrite "https://nginx.org/download/nginx-1.31.9.tar.gz")
[ "$rw_non" = "https://nginx.org/download/nginx-1.31.9.tar.gz" ] \
  && ok "url_rewrite 不改写非 GitHub URL" || bad "url_rewrite 误改非 GitHub URL: $rw_non"
github_mirror=""

mod_args=$(module_configure_args "stub_status,http_v3,headers_more,brotli")
echo "$mod_args" | grep -q -- "--with-http_stub_status_module" \
  && echo "$mod_args" | grep -q -- "--with-http_v3_module" \
  && echo "$mod_args" | grep -q -- "--add-module=../headers-more-nginx-module-" \
  && echo "$mod_args" | grep -q -- "--add-module=../ngx_brotli" \
  && ok "module_configure_args 支持逗号分隔多模块" \
  || bad "module_configure_args 异常: $mod_args"

# ---------------- 4. 通配符覆盖匹配测试 ----------------
section "4. wc_covers 通配符 SAN 匹配"
wc_covers "DNS:example.com DNS:*.example.com" "example.com"       && ok "wc_covers 匹配根域名"       || bad "wc_covers 未匹配根域名"
wc_covers "DNS:example.com DNS:*.example.com" "api.example.com"   && ok "wc_covers 匹配一级子域名"   || bad "wc_covers 未匹配一级子域名"
! wc_covers "DNS:example.com DNS:*.example.com" "a.b.example.com" && ok "wc_covers 拒绝二级子域名"   || bad "wc_covers 误匹配二级子域名"
! wc_covers "DNS:example.com DNS:*.example.com" "evil-example.com" && ok "wc_covers 拒绝相似域名"    || bad "wc_covers 误匹配相似域名"

# ---------------- 5. vhost 渲染与凭证转义测试 ----------------
section "5. emit_vhost / TLS 套件 / HTTP3 / dns.env 安全转义"
MAIN="demo.example.com"
DOMAINS_ARR=("demo.example.com" "www.demo.example.com")
SERVER_NAMES="${DOMAINS_ARR[*]}"
WEBROOT="/data/wwwroot/demo.example.com"
ACCESSLOG="y"
HOTLINK="y"
SSL_CRT="/usr/local/nginx/conf/ssl/demo.example.com/certificates/demo.example.com.crt"
SSL_KEY="/usr/local/nginx/conf/ssl/demo.example.com/certificates/demo.example.com.key"

ENABLE_HTTP3=0
out_ssl=$(emit_vhost ssl)
echo "$out_ssl" | grep -q "ECDHE-ECDSA-AES128-GCM-SHA256" && ! echo "$out_ssl" | grep -q "3DES" \
  && ok "SSL 套件已升级为现代 ECDHE (无 3DES)" || bad "SSL 套件异常"
echo "$out_ssl" | grep -q "access_log /data/wwwlogs/demo.example.com_nginx.log combined;" \
  && ok "emit_vhost 正确写入 server 级 access_log" || bad "emit_vhost access_log 异常"
echo "$out_ssl" | grep -q "valid_referers none blocked server_names" \
  && ok "emit_vhost 正确注入防盗链块" || bad "emit_vhost 防盗链块异常"
! echo "$out_ssl" | grep -q "listen 443 quic" \
  && ok "ENABLE_HTTP3=0 时不输出 quic 监听" || bad "未开启 HTTP3 却输出了 quic"

ENABLE_HTTP3=1
out_h3=$(emit_vhost ssl)
echo "$out_h3" | grep -q "listen 443 quic;" && echo "$out_h3" | grep -q 'Alt-Svc' \
  && ok "ENABLE_HTTP3=1 时输出 QUIC 监听与 Alt-Svc" || bad "HTTP3 配置未生成"
ENABLE_HTTP3=0

# 测试 write_renew_env & dns_provider_collect 权限与特殊字符转义
tmpdir=$(mktemp -d)
EAB_KID="kid_123" EAB_HMAC="hmac_secret" TLS_SKIP=0 DNS_PROVIDER="cloudflare" DNS_CRED_FILE="$tmpdir/dns.env" DNS_RESOLVERS_STR=""
write_renew_env "$tmpdir" "example.com *.example.com" "admin@example.com" "https://acme.example/dir" ""
perm_env=$(stat -c '%a' "$tmpdir/renew.env" 2>/dev/null || stat -f '%Lp' "$tmpdir/renew.env")
[ "$perm_env" = "600" ] && ok "renew.env 权限为 600" || bad "renew.env 权限异常: $perm_env"

export CLOUDFLARE_DNS_API_TOKEN="tok'with\"quotes\$and space"
ASSUME_YES=1
dns_provider_collect "$tmpdir" >/dev/null
perm_dns=$(stat -c '%a' "$tmpdir/dns.env" 2>/dev/null || stat -f '%Lp' "$tmpdir/dns.env")
[ "$perm_dns" = "600" ] && ok "dns.env 权限为 600" || bad "dns.env 权限异常: $perm_dns"
loaded_tok=$(bash -c ". '$tmpdir/dns.env'; printf '%s' \"\$CLOUDFLARE_DNS_API_TOKEN\"")
[ "$loaded_tok" = "tok'with\"quotes\$and space" ] \
  && ok "dns.env 安全转义含单引号/双引号/空格的密钥" \
  || bad "dns.env 转义还原不一致: $loaded_tok"
rm -rf "$tmpdir"

# ---------------- U6 lego-renew.sh 多账号环境变量隔离 ----------------
section "U6 lego-renew.sh 多账号 DNS 凭证隔离"
tmpdir=$(mktemp -d)
mkdir -p "$tmpdir/ssl/a.example.com" "$tmpdir/ssl/b.example.com"
cat > "$tmpdir/mock-lego.sh" <<EOF
#!/bin/bash
printf '%s|%s|%s\n' "\${TENCENTCLOUD_SECRET_ID:-}" "\${TENCENTCLOUD_SECRET_KEY:-}" "\${TENCENTCLOUD_SESSION_TOKEN:-}" >> "$tmpdir/lego-env.log"
EOF
chmod +x "$tmpdir/mock-lego.sh"
cat > "$tmpdir/ssl/a.example.com/dns.env" <<'EOF'
export TENCENTCLOUD_SECRET_ID=acct1
export TENCENTCLOUD_SECRET_KEY=key1
export TENCENTCLOUD_SESSION_TOKEN=tok1
EOF
cat > "$tmpdir/ssl/a.example.com/renew.env" <<EOF
DOMAINS="a.example.com *.a.example.com"
EMAIL="a@example.com"
SERVER="https://example.invalid/dir"
WEBROOT=""
DNS_PROVIDER="tencentcloud"
DNS_CRED_FILE="$tmpdir/ssl/a.example.com/dns.env"
EOF
cat > "$tmpdir/ssl/b.example.com/dns.env" <<'EOF'
export TENCENTCLOUD_SECRET_ID=acct2
export TENCENTCLOUD_SECRET_KEY=key2
EOF
cat > "$tmpdir/ssl/b.example.com/renew.env" <<EOF
DOMAINS="b.example.com *.b.example.com"
EMAIL="b@example.com"
SERVER="https://example.invalid/dir"
WEBROOT=""
DNS_PROVIDER="tencentcloud"
DNS_CRED_FILE="$tmpdir/ssl/b.example.com/dns.env"
EOF
sed -e "s|__NGINX_SSL__|$tmpdir/ssl|g" \
    -e "s|LEGO=/usr/local/bin/lego|LEGO=$tmpdir/mock-lego.sh|g" \
    "$LOCKLET_ROOT/config/lego-renew.sh.tmpl" > "$tmpdir/lego-renew.sh"
bash "$tmpdir/lego-renew.sh" >/dev/null 2>&1 \
  && ok "lego-renew.sh 多账号 mock 执行成功" || bad "lego-renew.sh 执行失败"
line1=$(sed -n '1p' "$tmpdir/lego-env.log")
line2=$(sed -n '2p' "$tmpdir/lego-env.log")
[ "$line1" = "acct1|key1|tok1" ] && ok "账号 1 凭证正确加载 ($line1)" || bad "账号 1 凭证异常: $line1"
[ "$line2" = "acct2|key2|" ] && ok "账号 2 凭证隔离正常, 无残留 SESSION_TOKEN ($line2)" || bad "账号 2 存在环境变量泄漏: $line2"
rm -rf "$tmpdir"

# ---------------- U7 ZeroSSL EAB JSON 解析 ----------------
section "U7 ZeroSSL EAB JSON 解析"
bash -c '
  . ./include/common.sh
  . ./include/vhost_acme.sh
  EAB_KID="" EAB_HMAC=""
  _parse_zerossl_eab_json "{\"success\":true,\"eab_kid\":\"kid123\",\"eab_hmac_key\":\"hmac456\"}"
  [ "$EAB_KID" = "kid123" ] && [ "$EAB_HMAC" = "hmac456" ]
' && ok "_parse_zerossl_eab_json 支持 eab-credentials-email 返回格式" || bad "eab-credentials-email JSON 解析失败"
bash -c '
  . ./include/common.sh
  . ./include/vhost_acme.sh
  EAB_KID="" EAB_HMAC=""
  _parse_zerossl_eab_json "{\"EABKID\":\"k2\",\"EABHMACKey\":\"h2\"}"
  [ "$EAB_KID" = "k2" ] && [ "$EAB_HMAC" = "h2" ]
' && ok "_parse_zerossl_eab_json 兼容 EABKID/EABHMACKey 格式" || bad "EABKID JSON 解析失败"

# ---------------- 汇总 ----------------
echo
printf "\033[36m============================================\033[0m\n"
printf " 通过: \033[32m%d\033[0m   失败: %s%d\033[0m\n" "$PASS" "$([ $FAIL -gt 0 ] && printf '\033[31m' || printf '\033[0m')" "$FAIL"
printf "\033[36m============================================\033[0m\n"
[ "$FAIL" -eq 0 ]
