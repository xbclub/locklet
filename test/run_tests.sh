#!/bin/bash
####################################################################
# locklet 容器内验收测试 (在目标机器上以 root 运行)
# 覆盖: 编译安装(1.31.9) / vhost http / 自有证书 SSL / Pebble ACME
#       完整签发 + 续期 + vhost 删除
####################################################################
set -u
cd "$(dirname "$0")/.."
LOCKLET_DIR=$(pwd)

PASS=0; FAIL=0
ok()  { printf " \033[32m✔\033[0m %s\n" "$1"; PASS=$((PASS+1)); }
bad() { printf " \033[31m✘\033[0m %s\n" "$1"; FAIL=$((FAIL+1)); }
section(){ printf "\n\033[36m== %s ==\033[0m\n" "$1"; }

# ---------------- T1 安装与版本 ----------------
section "T1 nginx 编译安装 (期望 1.31.9)"
ver=$(/usr/local/nginx/sbin/nginx -v 2>&1)
echo "$ver" | grep -q "1.31.9" && ok "nginx 版本: $ver" || bad "nginx 版本不符: $ver"

systemctl is-active nginx >/dev/null 2>&1 && ok "nginx 服务 active" || bad "nginx 服务未运行"
curl -fsS http://127.0.0.1/ | grep -q "locklet" && ok "默认站点可访问 (curl 127.0.0.1)" || bad "默认站点不可访问"
id -u www >/dev/null 2>&1 && ok "www 用户存在" || bad "www 用户不存在"
[ -d /data/wwwroot/default ] && ok "/data/wwwroot/default 存在" || bad "/data/wwwroot/default 缺失"
/usr/local/nginx/sbin/nginx -V 2>&1 | grep -q "http_v2_module" && ok "http_v2_module 已编译" || bad "http_v2_module 缺失"
/usr/local/nginx/sbin/nginx -V 2>&1 | grep -q "stream_ssl_preread_module" && ok "stream_ssl_preread_module 已编译" || bad "stream_ssl_preread_module 缺失"
/usr/local/nginx/sbin/nginx -V 2>&1 | grep -q -- "--with-threads" && ok "--with-threads 已编译" || bad "--with-threads 缺失"
/usr/local/nginx/sbin/nginx -V 2>&1 | grep -q -- "--with-file-aio" && ok "--with-file-aio 已编译" || bad "--with-file-aio 缺失"
/usr/local/nginx/sbin/nginx -V 2>&1 | grep -q "http_auth_request_module" && ok "http_auth_request_module 已编译" || bad "http_auth_request_module 缺失"
/usr/local/nginx/sbin/nginx -V 2>&1 | grep -q "http_gunzip_module" && ok "http_gunzip_module 已编译" || bad "http_gunzip_module 缺失"
/usr/local/nginx/sbin/nginx -V 2>&1 | grep -q "stream_realip_module" && ok "stream_realip_module 已编译" || bad "stream_realip_module 缺失"
# 加固编译选项 (对齐官方 Debian 包 hardening flags)
/usr/local/nginx/sbin/nginx -V 2>&1 | grep -q -- "--with-cc-opt='-O2 -fstack-protector-strong" \
  && ok "cc-opt 加固参数生效 (-O2 -fstack-protector-strong ...)" || bad "cc-opt 加固参数缺失"
/usr/local/nginx/sbin/nginx -V 2>&1 | grep -q -- "--with-ld-opt='-Wl,-z,relro" \
  && ok "ld-opt 加固参数生效 (RELRO/now/pie)" || bad "ld-opt 加固参数缺失"
readelf -l /usr/local/nginx/sbin/nginx 2>/dev/null | grep -q GNU_RELRO \
  && ok "二进制含 GNU_RELRO 段" || bad "GNU_RELRO 缺失"
readelf -d /usr/local/nginx/sbin/nginx 2>/dev/null | grep -q BIND_NOW \
  && ok "BIND_NOW (full RELRO)" || bad "BIND_NOW 缺失"
readelf -h /usr/local/nginx/sbin/nginx 2>/dev/null | grep -q "Type:.*DYN" \
  && ok "PIE 可执行文件 (Type: DYN)" || bad "非 PIE (Type: EXEC)"
readelf -s /usr/local/nginx/sbin/nginx 2>/dev/null | grep -q __stack_chk_fail \
  && ok "栈保护生效 (__stack_chk_fail 存在)" || bad "栈保护缺失"
command -v /usr/local/bin/lego >/dev/null && ok "lego 已安装: $(/usr/local/bin/lego --version 2>&1 | head -1)" || bad "lego 未安装"
systemctl is-enabled lego-renew.timer >/dev/null 2>&1 && ok "lego-renew.timer 已启用" || bad "lego-renew.timer 未启用"

# ---------------- T2 http vhost ----------------
section "T2 vhost 添加 (http)"
./vhost.sh del -d test1.local --purge-webroot --purge-ssl --yes >/dev/null 2>&1
./vhost.sh add -d test1.local -w /data/wwwroot/test1 --rewrite wordpress --accesslog y --ssl none --yes >/dev/null 2>&1
[ -f /usr/local/nginx/conf/vhost/test1.local.conf ] && ok "vhost conf 已生成" || bad "vhost conf 未生成"
code=$(curl -s -o /tmp/t1.html -w '%{http_code}' -H 'Host: test1.local' http://127.0.0.1/)
[ "$code" = "200" ] && ok "curl Host=test1.local -> 200" || bad "curl test1.local -> $code"
grep -q "wordpress" /usr/local/nginx/conf/rewrite/test1.local.conf && ok "wordpress 伪静态已注入" || bad "伪静态未注入"
./vhost.sh list | grep -q "test1.local" && ok "vhost list 显示 test1.local" || bad "vhost list 缺失"

# ---------------- T3 自有证书 SSL ----------------
section "T3 vhost SSL (自有证书 + 强制跳转)"
./vhost.sh del -d test2.local --purge-webroot --purge-ssl --yes >/dev/null 2>&1
mkdir -p /etc/locklet-test
openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
  -keyout /etc/locklet-test/test2.key -out /etc/locklet-test/test2.crt \
  -subj "/CN=test2.local" >/dev/null 2>&1
./vhost.sh add -d test2.local --ssl custom \
  --cert /etc/locklet-test/test2.crt --key /etc/locklet-test/test2.key \
  --force-https y --yes >/dev/null 2>&1
code=$(curl -sk -o /dev/null -w '%{http_code}' --resolve test2.local:443:127.0.0.1 https://test2.local/)
[ "$code" = "200" ] && ok "https test2.local -> 200" || bad "https test2.local -> $code"
code=$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: test2.local' http://127.0.0.1/)
[ "$code" = "301" ] && ok "http -> 301 跳转" || bad "http -> $code (期望 301)"
./vhost.sh list | grep -q "test2.local" && ok "vhost list 含 test2.local" || bad "vhost list 缺失"

# ---------------- T4 Pebble ACME ----------------
section "T4 lego + Pebble (本地 ACME 服务器)"
install_go() {
  if command -v go >/dev/null 2>&1 && [ "$(go version | grep -c 'go1\.\(2[5-9]\|[3-9][0-9]\)')" -ge 1 ]; then
    return 0
  fi
  local gver
  gver=$(curl -s 'https://go.dev/dl/?mode=json' | grep -o 'go1\.[0-9]*\.[0-9]*' | head -1)
  [ -n "$gver" ] || gver=go1.25.5
  curl -fsSL -o /tmp/go.tgz "https://go.dev/dl/${gver}.linux-amd64.tar.gz"
  rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tgz
  export PATH=/usr/local/go/bin:$PATH
}
install_go && ok "go: $(go version)" || bad "go 安装失败"

if [ ! -d /opt/pebble ]; then
  git clone --depth 1 https://github.com/letsencrypt/pebble /opt/pebble >/dev/null 2>&1 || bad "pebble 克隆失败"
fi
if [ ! -x /usr/local/bin/pebble ] && [ -d /opt/pebble ]; then
  (cd /opt/pebble && GOPATH=/root/go go build -o /usr/local/bin/pebble ./cmd/pebble >/dev/null 2>&1) \
    && ok "pebble 编译完成" || bad "pebble 编译失败"
fi
port_open() { (exec 3<>/dev/tcp/127.0.0.1/14000) 2>/dev/null; }
if ! port_open; then
  (cd /opt/pebble && PEBBLE_VA_NOSLEEP=1 PEBBLE_VA_ALWAYS_VALID=1 \
     nohup /usr/local/bin/pebble >/var/log/pebble.log 2>&1 &)
  for i in $(seq 1 20); do port_open && break; sleep 1; done
fi
port_open && ok "pebble 运行于 :14000" || bad "pebble 未监听 (见 /var/log/pebble.log)"

./vhost.sh del -d test3.local --purge-webroot --purge-ssl --yes >/dev/null 2>&1
./vhost.sh add -d test3.local --ssl le \
  --ca-url https://localhost:14000/dir --tls-skip-verify \
  --email admin@test.local --yes >/tmp/t4.log 2>&1
CRT=/usr/local/nginx/conf/ssl/test3.local/certificates/test3.local.crt
[ -f "$CRT" ] && ok "ACME 证书已签发: $CRT" || { bad "证书未签发"; tail -30 /tmp/t4.log; }
if [ -f "$CRT" ]; then
  issuer=$(openssl x509 -in "$CRT" -noout -issuer)
  echo "$issuer" | grep -qi pebble && ok "证书颁发机构 = Pebble ($issuer)" || bad "颁发机构异常: $issuer"
  code=$(curl -sk -o /dev/null -w '%{http_code}' --resolve test3.local:443:127.0.0.1 https://test3.local/)
  [ "$code" = "200" ] && ok "https test3.local -> 200" || bad "https test3.local -> $code"
fi
[ -f /usr/local/nginx/conf/ssl/test3.local/renew.env ] && ok "renew.env 已保存" || bad "renew.env 缺失"

# ---------------- T5 续期 ----------------
section "T5 lego 续期 (renew.env 参数复用)"
if [ -f "$CRT" ]; then
  serial1=$(openssl x509 -in "$CRT" -noout -serial | cut -d= -f2)
  # 用 --renew-days 200 强制进入续期窗口 (pebble 默认证书 90 天)
  ( . /usr/local/nginx/conf/ssl/test3.local/renew.env
    args=(--server "$SERVER" --path /usr/local/nginx/conf/ssl/test3.local
          --http --http.webroot "$WEBROOT" --accept-tos --tls-skip-verify)
    for d in $DOMAINS; do args+=(--domains "$d"); done
    /usr/local/bin/lego run "${args[@]}" --renew-days 200 --no-random-sleep --ari-disable \
      --deploy-hook "/bin/systemctl reload nginx" ) >/tmp/t5.log 2>&1 \
    && ok "lego 续期命令执行成功" || { bad "lego 续期失败"; tail -20 /tmp/t5.log; }
  serial2=$(openssl x509 -in "$CRT" -noout -serial | cut -d= -f2)
  [ "$serial1" != "$serial2" ] && ok "证书已更新 ($serial1 -> $serial2)" || bad "证书未更新"
  systemctl is-active nginx >/dev/null 2>&1 && ok "续期后 nginx 仍 active" || bad "续期后 nginx 异常"

  /usr/local/bin/lego-renew.sh >/tmp/t5b.log 2>&1 \
    && ok "lego-renew.sh 定时脚本执行成功" || { bad "lego-renew.sh 失败"; tail -20 /tmp/t5b.log; }
  grep -q "距到期" /tmp/t5b.log && ok "renew 脚本正确跳过未到期证书" || bad "renew 脚本输出异常"
fi

# ---------------- T6 删除 ----------------
section "T6 vhost 删除"
./vhost.sh del -d test1.local --purge-webroot --purge-ssl --yes >/dev/null 2>&1
[ ! -f /usr/local/nginx/conf/vhost/test1.local.conf ] && ok "vhost conf 已删除" || bad "vhost conf 残留"
[ ! -d /data/wwwroot/test1 ] && ok "webroot 已删除" || bad "webroot 残留"
sleep 3  # 等待 reload 生效 (重试一次防竞态)
body=$(curl -s -H 'Host: test1.local' http://127.0.0.1/)
echo "$body" | grep -q "locklet" || { sleep 2; body=$(curl -s -H 'Host: test1.local' http://127.0.0.1/); }
echo "$body" | grep -q "locklet" && ok "删除后回落到默认站点 (locklet 默认页)" || bad "删除后未回落默认站点: $(echo "$body" | head -1)"
/usr/local/nginx/sbin/nginx -t >/dev/null 2>&1 && ok "nginx -t 通过" || bad "nginx -t 失败"

# ---------------- T7 通配符证书 ----------------
section "T7 通配符证书 (DNS-01 + pebble)"
# 本地权威 DNS (dnsmasq auth-zone): 让 lego manual provider 能找到 test4.local 区域
port_open_5353() { (exec 3<>/dev/tcp/127.0.0.1/5353) 2>/dev/null; }
if ! command -v dnsmasq >/dev/null 2>&1; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y dnsmasq >/dev/null 2>&1
fi
if command -v dnsmasq >/dev/null 2>&1; then
  if ! port_open_5353; then
    (nohup dnsmasq --no-daemon --port=5353 --listen-address=127.0.0.1 \
        --auth-server=test4.local --auth-zone=test4.local \
        >/var/log/dnsmasq-test.log 2>&1 &)
    for i in $(seq 1 15); do port_open_5353 && break; sleep 1; done
  fi
  port_open_5353 && ok "dnsmasq 权威 DNS 运行于 127.0.0.1:5353 (test4.local)" || bad "dnsmasq 未监听"
else
  bad "dnsmasq 安装失败"
fi

# 申请通配符: *.test4.local (manual provider + pebble)
./vhost.sh wildcard -d test4.local --ssl le --dns manual \
  --ca-url https://localhost:14000/dir --tls-skip-verify --dns-resolvers 127.0.0.1:5353 \
  --email admin@test.local --yes >/tmp/t7.log 2>&1
WCRT=/usr/local/nginx/conf/ssl/test4.local/certificates/test4.local.crt
if [ -f "$WCRT" ]; then
  ok "通配符证书已签发: $WCRT"
  sans=$(openssl x509 -in "$WCRT" -noout -ext subjectAltName 2>/dev/null | grep -o 'DNS:[^ ,]*' | tr '\n' ' ')
  echo "$sans" | grep -q 'DNS:\*\.test4\.local' && ok "SANs 含通配符: $sans" || bad "SANs 缺通配符: $sans"
  issuer=$(openssl x509 -in "$WCRT" -noout -issuer)
  echo "$issuer" | grep -qi pebble && ok "通配符证书 CA = Pebble" || bad "通配符 CA 异常: $issuer"
  grep -q 'DNS_PROVIDER="manual"' /usr/local/nginx/conf/ssl/test4.local/renew.env \
    && ok "renew.env 记录 DNS_PROVIDER=manual" || bad "renew.env 缺 DNS_PROVIDER"
else
  bad "通配符证书未签发"; tail -30 /tmp/t7.log
fi

# vhost 复用通配符证书
./vhost.sh add -d abc.test4.local --ssl wildcard --use-wildcard test4.local --yes >/tmp/t7b.log 2>&1
VCONF=/usr/local/nginx/conf/vhost/abc.test4.local.conf
if grep -q "ssl/test4.local/certificates/test4.local.crt" "$VCONF" 2>/dev/null; then
  ok "vhost abc.test4.local 复用通配符证书"
  code=$(curl -sk -o /dev/null -w '%{http_code}' --resolve abc.test4.local:443:127.0.0.1 https://abc.test4.local/)
  [ "$code" = "200" ] && ok "https abc.test4.local (通配符) -> 200" || bad "https abc.test4.local -> $code"
else
  bad "vhost 未使用通配符证书"; tail -20 /tmp/t7b.log
fi
./vhost.sh list | grep -q '\*\.test4\.local' && ok "vhost list 显示通配符证书区" || bad "list 未显示通配符"

# 通配符续期: lego-renew.sh 验证脚本路径 (90 天证书未到 30 天阈值, 应正确跳过);
# 再用 --renew-days 200 强制续期验证 DNS-01 续期链路 (manual 自动应答)
if [ -f "$WCRT" ]; then
  serial1=$(openssl x509 -in "$WCRT" -noout -serial | cut -d= -f2)
  yes "" | /usr/local/bin/lego-renew.sh >/tmp/t7c.log 2>&1 \
    && grep -q "test4.local: OK" /tmp/t7c.log \
    && ok "lego-renew.sh DNS-01 续期脚本执行成功 (未到期正确跳过)" \
    || { bad "lego-renew.sh 失败"; tail -20 /tmp/t7c.log; }
  ( . /usr/local/nginx/conf/ssl/test4.local/renew.env
    yes "" | /usr/local/bin/lego run --server "$SERVER" \
      --path /usr/local/nginx/conf/ssl/test4.local --accept-tos --tls-skip-verify \
      --dns manual --dns.propagation.wait 1s --dns.resolvers 127.0.0.1:5353 \
      --domains test4.local --domains '*.test4.local' \
      --renew-days 200 --no-random-sleep --ari-disable \
      --deploy-hook "/bin/systemctl reload nginx" ) >/tmp/t7e.log 2>&1 \
    && ok "通配符强制续期命令执行成功" || { bad "通配符强制续期失败"; tail -20 /tmp/t7e.log; }
  serial2=$(openssl x509 -in "$WCRT" -noout -serial | cut -d= -f2)
  [ "$serial1" != "$serial2" ] && ok "通配符证书已续期 ($serial1 -> $serial2)" || bad "通配符证书未更新"
  systemctl is-active nginx >/dev/null 2>&1 && ok "续期后 nginx 仍 active" || bad "续期后 nginx 异常"
fi

# 删除复用通配符的 vhost: 证书应保留
./vhost.sh del -d abc.test4.local --purge-webroot --purge-ssl --yes >/tmp/t7d.log 2>&1
[ ! -f "$VCONF" ] && ok "vhost abc.test4.local 已删除" || bad "vhost 残留"
[ -f "$WCRT" ] && ok "共享通配符证书已保留 (未被误删)" || bad "通配符证书被误删!"

# ---------------- T8 官方 deb 模式 (源码版迁移) ----------------
section "T8 官方 deb 模式 (source -> deb 迁移)"
/root/locklet/install.sh --auto >/tmp/t8-install.log 2>&1
rc=$?
if [ $rc -eq 0 ] && dpkg -s nginx >/dev/null 2>&1; then
  ok "install.sh --auto (默认 deb) 安装成功"
else
  bad "deb 安装失败 (rc=$rc)"; tail -20 /tmp/t8-install.log
fi
dpkg -s nginx >/dev/null 2>&1 && ok "dpkg 包已安装: $(dpkg-query -W -f='${Version}' nginx)" || bad "dpkg 未安装 nginx"
deb_ver=$(/usr/sbin/nginx -v 2>&1 | sed -n 's|.*nginx/\([0-9]*\.[0-9]*\.[0-9]*\).*|\1|p')
deb_minor=$(echo "$deb_ver" | cut -d. -f2)
if [ -n "$deb_ver" ] && [ $((deb_minor % 2)) -eq 0 ]; then
  ok "官方 stable 版本 $deb_ver (次版本号为偶数)"
else
  bad "版本异常: $(/usr/sbin/nginx -v 2>&1)"
fi
systemctl is-active nginx >/dev/null 2>&1 && ok "nginx (deb) 服务 active" || bad "nginx 服务未运行"
curl -fsS http://127.0.0.1/ >/dev/null && ok "默认站点可访问" || bad "默认站点不可访问"
grep -q "^install_mode=deb" /root/locklet/options.conf && ok "options.conf 回写 install_mode=deb" || bad "options.conf 未回写"
[ -f /etc/nginx/conf.d/test3.local.conf ] && ok "vhost 已迁移到 /etc/nginx/conf.d" || bad "vhost 未迁移"
[ -f /etc/nginx/ssl/test3.local/certificates/test3.local.crt ] && ok "证书已迁移到 /etc/nginx/ssl" || bad "证书未迁移"
grep -q "/etc/nginx/ssl/test3.local" /etc/nginx/conf.d/test3.local.conf && ok "conf 内证书路径已改写" || bad "conf 内路径未改写"
grep -q 'DNS_CRED_FILE="/etc/nginx/ssl/test4.local/dns.env"' /etc/nginx/ssl/test4.local/renew.env \
  && ok "renew.env 内 DNS_CRED_FILE 路径已改写" || bad "renew.env 内 DNS_CRED_FILE 未改写"
ls -d /usr/local/nginx.bak-* >/dev/null 2>&1 && [ ! -e /usr/local/nginx ] && ok "旧目录已备份为 .bak-*" || bad "旧目录处理异常"
/usr/sbin/nginx -t >/dev/null 2>&1 && ok "nginx -t 通过 (迁移后)" || bad "nginx -t 失败"
code=$(curl -sk -o /dev/null -w '%{http_code}' --resolve test3.local:443:127.0.0.1 https://test3.local/)
[ "$code" = "200" ] && ok "迁移后 https test3.local -> 200" || bad "迁移后 https -> $code"
cd /root/locklet && ./vhost.sh list | grep -q "test3.local" && ok "vhost list (deb 模式) 正常" || bad "vhost list 异常"
./vhost.sh add -d test5.local --ssl none --yes >/dev/null 2>&1
code=$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: test5.local' http://127.0.0.1/)
[ "$code" = "200" ] && ok "deb 模式新增 vhost -> 200" || bad "deb 模式新增 vhost -> $code"

# ---------------- T9 自动升级 ----------------
section "T9 自动升级 timer (deb)"
systemctl is-enabled locklet-upgrade.timer >/dev/null 2>&1 && ok "locklet-upgrade.timer 已启用" || bad "upgrade timer 未启用"
/usr/local/bin/locklet-upgrade.sh >/tmp/t9.log 2>&1 && ok "升级脚本执行成功" || { bad "升级脚本失败"; tail -10 /tmp/t9.log; }
grep -q "deb 已是最新" /tmp/t9.log && ok "deb 通道已是最新 (正确判定)" || bad "升级判定异常: $(tail -1 /tmp/t9.log)"
systemctl is-active nginx >/dev/null 2>&1 && ok "升级检查后 nginx 仍 active" || bad "nginx 异常"

# ---------------- T10 切回源码模式 (deb -> source 迁移) ----------------
section "T10 切回源码模式 (deb -> source 迁移)"
/root/locklet/install.sh --auto --source >/tmp/t10-install.log 2>&1
rc=$?
if [ $rc -eq 0 ]; then ok "install.sh --auto --source 安装成功"; else bad "source 安装失败 (rc=$rc)"; tail -20 /tmp/t10-install.log; fi
/usr/local/nginx/sbin/nginx -v 2>&1 | grep -q "1.31.9" && ok "源码编译 1.31.9" || bad "版本异常: $(/usr/local/nginx/sbin/nginx -v 2>&1)"
dpkg -s nginx >/dev/null 2>&1 && bad "deb 包未卸载" || ok "deb 包已卸载"
systemctl is-active nginx >/dev/null 2>&1 && ok "nginx (source) 服务 active" || bad "nginx 服务未运行"
[ -f /usr/local/nginx/conf/vhost/test3.local.conf ] && ok "vhost 已恢复到 conf/vhost" || bad "vhost 未恢复"
[ -f /usr/local/nginx/conf/ssl/test3.local/certificates/test3.local.crt ] && ok "证书已恢复" || bad "证书未恢复"
grep -q 'DNS_CRED_FILE="/usr/local/nginx/conf/ssl/test4.local/dns.env"' /usr/local/nginx/conf/ssl/test4.local/renew.env \
  && ok "renew.env 内 DNS_CRED_FILE 已改写回 source 路径" || bad "renew.env 内 DNS_CRED_FILE 未改写回 source 路径"
code=$(curl -sk -o /dev/null -w '%{http_code}' --resolve test3.local:443:127.0.0.1 https://test3.local/)
[ "$code" = "200" ] && ok "恢复后 https test3.local -> 200" || bad "恢复后 https -> $code"
/usr/local/nginx/sbin/nginx -t >/dev/null 2>&1 && ok "nginx -t 通过 (恢复后)" || bad "nginx -t 失败"
./vhost.sh list | grep -q "test3.local" && ok "vhost list (source 模式) 正常" || bad "vhost list 异常"
/usr/local/bin/locklet-upgrade.sh >/tmp/t10b.log 2>&1 && ok "source 模式升级脚本执行成功" || { bad "升级脚本失败"; tail -10 /tmp/t10b.log; }
grep -qE "已是最新|不低于仓库版本" /tmp/t10b.log && ok "source 通道升级判定正确 (1.31.9 vs stable 1.30.7)" || bad "判定异常: $(tail -1 /tmp/t10b.log)"

# ---------------- 汇总 ----------------
echo
printf "\033[36m============================================\033[0m\n"
printf " 通过: \033[32m%d\033[0m   失败: %s%d\033[0m\n" "$PASS" "$([ $FAIL -gt 0 ] && printf '\033[31m' || printf '\033[0m')" "$FAIL"
printf "\033[36m============================================\033[0m\n"
[ "$FAIL" -eq 0 ]
