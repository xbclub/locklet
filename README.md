# locklet

nginx + lego 一键安装 / vhost 管理 / SSL 证书工具集, 采用 [oneinstack](https://oneinstack.com) 的设计模式(交互菜单 + options.conf + include 模块化)。

## 特性

- **双安装模式**
  - **deb (默认)**: nginx.org 官方 deb 包 (stable 通道), 自动配置 apt 源/key/pin,
    跟随官方仓库升级; `--channel mainline` 可切 mainline
  - **source (显式)**: 源码编译 (最小化参数 + 加固 + 可选模块), `--source` 或
    `--nginx-version` 触发; 两种模式可随时互切, vhost/证书/伪静态自动迁移
- **自动升级**: `locklet-upgrade.timer` 每周日 04:30 — deb 模式走 apt;
  source 模式自动检测官方新版本并重编 (保留现有配置)
- **源码模式编译参数可配置**
  - 核心参数即"最小化编译参数"(见下), 保证与目标环境一致
  - 可选附加模块: `stub_status` `http_v3`(QUIC) `sub_module` `headers_more` `brotli`
  - pcre2 / zlib / openssl 均为源码内置编译(oneinstack 同款做法), 不污染系统库
- **www 运行用户**, 路径与 oneinstack 保持一致:
  - `/usr/local/nginx` nginx 安装目录
  - `/data/wwwroot` 网站根目录(默认站点 `/data/wwwroot/default`)
  - `/data/wwwlogs` 日志目录
  - vhost: `/usr/local/nginx/conf/vhost/*.conf`, 伪静态: `conf/rewrite/`
- **lego** (v5.6.0) ACME 客户端, `--path /usr/local/nginx/conf/ssl/<域名>/`
  - 可指定证书颁发机构: **Let's Encrypt (正式/staging)** 或 **ZeroSSL** (API key 自动获取 EAB, 或手动 EAB kid/hmac)
  - HTTP-01 webroot 验证, 签发/续期后自动 reload nginx (`--deploy-hook`)
  - 每日 03:30 systemd timer 自动续期(`--renew-days 30`)
- **vhost.sh** 站点管理: 添加/列表/删除/补 SSL, 交互或纯命令行(可脚本化)
  - 列表会显示每个站点证书的 **颁发机构与到期时间**
- **通配符证书** (`*.example.com`, DNS-01 验证)
  - 支持 cloudflare / aliyun / dnspod / tencentcloud / godaddy 及 lego 全部 DNS 提供商
  - 凭证保存在 `conf/ssl/<域名>/dns.env` (600), timer 自动续期
  - 添加子域名 vhost 时直接复用: `--ssl wildcard`

## 核心编译参数 (最小化)

```
./auto/configure \
  --prefix=/usr/local/nginx \
  --user=www \
  --group=www \
  --with-http_v2_module \
  --with-http_ssl_module \
  --with-stream \
  --with-stream_ssl_preread_module \
  --with-stream_ssl_module \
  --with-http_gzip_static_module \
  --with-http_realip_module \
  --with-http_flv_module \
  --with-http_mp4_module \
  --with-http_addition_module \
  --with-threads \
  --with-file-aio \
  --with-http_auth_request_module \
  --with-http_gunzip_module \
  --with-stream_realip_module \
  --with-pcre=../pcre2-<ver> --with-pcre-jit \
  --with-zlib=../zlib-<ver> \
  --with-openssl=../openssl-<ver> --with-openssl-opt=no-tests \
  --with-cc-opt='-O2 -fstack-protector-strong -Wformat -Werror=format-security -D_FORTIFY_SOURCE=2 -fPIC' \
  --with-ld-opt='-Wl,-z,relro -Wl,-z,now -Wl,--as-needed -pie'
```

加固编译选项对齐 nginx.org 官方 Debian 包 (dpkg-buildflags): 栈保护 / 格式化字符串检查 /
FORTIFY_SOURCE / PIC / full RELRO / PIE。可在 `options.conf` 的 `nginx_cc_opt` / `nginx_ld_opt` 调整。

## 安装

```bash
./install.sh              # 交互安装 (默认官方 stable deb 包)
./install.sh --auto       # 无人值守, 默认 = 官方 stable deb 包 + 自动升级

# 源码编译 (显式指定)
./install.sh --auto --source --nginx-version 1.31.9 \
             --nginx-module "stub_status,http_v3" \
             --mirror https://mirror.ghproxy.com/   # github 加速

# deb 模式切 mainline 通道 / 关闭自动升级
./install.sh --auto --channel mainline
./install.sh --auto --no-auto-upgrade
```

模式互切: 直接再跑一次 install.sh 即可 (`./install.sh --auto` ↔ `--source`),
vhost / 证书 / 伪静态 / dns.env 自动迁移, conf 内绝对路径自动改写。
升级: `systemctl list-timers | grep upgrade` 或手动 `/usr/local/bin/locklet-upgrade.sh`。

## vhost 管理

```bash
./vhost.sh                 # 交互菜单: 添加/列表/删除/补SSL
./vhost.sh list            # 查看所有站点 + 证书颁发机构 + 到期时间
./vhost.sh add -d www.example.com -d example.com \
              -w /data/wwwroot/example \
              --rewrite wordpress --accesslog y \
              --ssl le --email admin@example.com
./vhost.sh ssl -d www.example.com --ssl zerossl --email you@x.com \
              --zerossl-key <api-key>          # 后补/更换证书
./vhost.sh del -d www.example.com --purge-webroot
```

SSL 模式: `le`(Let's Encrypt 正式) / `le-staging`(测试) / `zerossl` / `custom`(自有证书) / `wildcard`(复用通配符) / `none`

### 通配符证书 (DNS-01)

```bash
# 申请: 自动覆盖 example.com + *.example.com, 凭证交互输入后保存 (600)
./vhost.sh wildcard -d example.com --dns cloudflare --email you@x.com
# 无人值守: 凭证通过环境变量传入
CLOUDFLARE_DNS_API_TOKEN=xxx ./vhost.sh wildcard -d example.com --dns cloudflare \
    --email you@x.com --yes

# 子域名 vhost 直接复用通配符 (不再单独签发/续期)
./vhost.sh add -d api.example.com --ssl wildcard --yes     # 自动匹配
./vhost.sh add -d api.example.com --ssl wildcard --use-wildcard example.com --yes

./vhost.sh list          # 底部显示通配符证书区 (SANs / CA / 到期)
```

DNS 提供商: `cloudflare` `aliyun` `dnspod` `tencentcloud` `godaddy` `manual`(测试用) 及
lego 支持的其他提供商(交互选择"其他"后输入, 见 `lego dnshelp`)。
通配符与普通证书一样由 `lego-renew.timer` 自动续期(DNS 凭证复用 dns.env)。

高级: `--ca-url <dir-url>` 覆盖 ACME 目录地址(自建 step-ca / pebble 测试), 配合 `--tls-skip-verify`。
lego v5 注意: 所有参数跟在 `run` 子命令之后; 续期窗口用 `--renew-days`(默认脚本 30 天)。

## 目录结构

```
├── install.sh              # 一键安装入口
├── vhost.sh                # vhost/SSL 管理
├── options.conf            # 版本/路径/模块配置
├── include/                # oneinstack 风格功能模块
│   ├── common.sh           #   输出/工具函数
│   ├── check_os.sh         #   OS 检测 + 依赖安装
│   ├── download.sh         #   下载(镜像/重试/校验)
│   ├── nginx.sh            #   www 用户/编译/systemd
│   └── lego.sh             #   lego 安装 + 续期 timer
├── config/                 # 配置模板
│   ├── nginx.conf.tmpl / default.conf.tmpl / index.html.tmpl
│   ├── nginx.service.tmpl / lego-renew.{sh,service,timer}.tmpl
│   └── rewrite/            # 伪静态模板 (none/wordpress/typecho/laravel)
└── src/                    # 运行时下载的源码 (自动生成)
```

## 证书续期

每个域名在 `conf/ssl/<域名>/renew.env` 保存签发参数, `lego-renew.timer`
每天 03:30 调用 `/usr/local/bin/lego-renew.sh` 逐域名续期, 成功后自动 reload nginx:

```bash
systemctl list-timers | grep lego
/usr/local/bin/lego-renew.sh        # 手动触发一次
```

## 测试

`test/run_tests.sh` 在干净容器内完整验证: 编译安装(1.31.9) → vhost http →
自定义证书 SSL → 本地 Pebble ACME 服务器模拟 CA 完成 lego 签发/续期全流程
(Pebble = Let's Encrypt 官方 ACME 测试服务, `PEBBLE_VA_ALWAYS_VALID=1` 跳过真实域名验证) →
通配符证书 (dnsmasq 本地权威 DNS + manual provider 模拟 DNS-01)。
