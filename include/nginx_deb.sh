#!/bin/bash
# nginx.org 官方 deb 包安装 (默认模式) + 与源码版互相迁移

DEB_KEYRING=/etc/apt/keyrings/nginx.asc
DEB_SRC_LIST=/etc/apt/sources.list.d/nginx.list
DEB_PIN=/etc/apt/preferences.d/99-locklet-nginx

install_depend_deb() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null 2>&1 || apt-get update -y
  apt-get install -y curl ca-certificates >/dev/null 2>&1 \
    || apt-get install -y curl ca-certificates
  step_ok "deb 模式依赖安装完成"
}

# 源码版 -> deb 版迁移 (在 apt 安装前调用)
migrate_from_source() {
  dpkg -s nginx >/dev/null 2>&1 && return 0          # 已是 deb
  [ -x "$nginx_sbin" ] || return 0                    # 无源码版
  [ "$install_mode" = "deb" ] || return 0

  local ts
  ts=$(date +%Y%m%d%H%M%S)
  log_info "检测到源码版 nginx, 迁移 vhost/证书到官方 deb 布局..."
  systemctl stop nginx 2>/dev/null
  systemctl disable nginx 2>/dev/null
  # 我们的自定义 unit 在 /etc 下, 优先级高于 deb 的 /lib unit, 必须移除
  rm -f /etc/systemd/system/nginx.service
  systemctl daemon-reload
  DEB_MIGRATE_OLD_PREFIX="$nginx_prefix"
  mv "$nginx_prefix" "${nginx_prefix}.bak-${ts}"
  step_ok "旧目录保留于 ${nginx_prefix}.bak-${ts}"
}

# apt 安装后: 恢复迁移数据 + 布局适配
install_nginx_deb() {
  local codename
  # shellcheck disable=SC1091
  . /etc/os-release
  codename="${VERSION_CODENAME:-}"
  [ -n "$codename" ] || log_fatal "无法识别发行版代号 (VERSION_CODENAME)"

  local repo_url="https://nginx.org/packages/debian"
  [ "$nginx_channel" = "mainline" ] && repo_url="https://nginx.org/packages/mainline/debian"

  # 1) 官方签名 key + 源 + pin (优先官方源, 避免被发行版旧包顶掉)
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://nginx.org/keys/nginx_signing.key -o "$DEB_KEYRING" \
    || log_fatal "下载 nginx 签名 key 失败"
  echo "deb [signed-by=$DEB_KEYRING] $repo_url $codename nginx" > "$DEB_SRC_LIST"
  cat > "$DEB_PIN" <<EOF
Package: nginx*
Pin: origin nginx.org
Pin-Priority: 900
EOF
  apt-get update >/dev/null 2>&1 || apt-get update
  step_ok "nginx.org 官方 apt 源就绪 ($nginx_channel/$codename)"

  # 2) 安装 (失败时输出日志便于排查)
  #    注意: 源码模式写过的 /etc/logrotate.d/nginx 与官方包 conffile 同名,
  #    会触发 dpkg 交互提示导致非交互安装失败 -> 先移除, 由官方包接管
  export DEBIAN_FRONTEND=noninteractive
  [ -f /etc/logrotate.d/nginx ] && mv -f /etc/logrotate.d/nginx /etc/logrotate.d/nginx.locklet.bak
  apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
    nginx >/tmp/locklet_apt_nginx.log 2>&1 \
    || { dpkg --configure -a >>/tmp/locklet_apt_nginx.log 2>&1; apt-get install -y nginx >>/tmp/locklet_apt_nginx.log 2>&1; }
  command -v /usr/sbin/nginx >/dev/null 2>&1 || { tail -30 /tmp/locklet_apt_nginx.log; log_fatal "deb 包安装失败 (见 /tmp/locklet_apt_nginx.log)"; }
  [ -f /etc/nginx/nginx.conf ] || { tail -30 /tmp/locklet_apt_nginx.log; log_fatal "apt 安装异常: /etc/nginx/nginx.conf 缺失"; }
  step_ok "nginx 已安装: $(/usr/sbin/nginx -v 2>&1)"

  # 3) 布局适配 (oneinstack 风格 www 用户 / /data/wwwroot / 0.default)
  sed -i -E 's|^user([[:space:]]+)nginx;|user\1'"$www_user"';|' /etc/nginx/nginx.conf
  grep -q "^user.*${www_user};" /etc/nginx/nginx.conf || log_warn "未找到 user 指令, 请手工调整 /etc/nginx/nginx.conf"
  rm -f /etc/nginx/conf.d/default.conf   # 官方默认页换为 locklet 默认页
  mkdir -p /etc/nginx/conf.d /etc/nginx/rewrite /etc/nginx/ssl "$wwwroot_dir/default" "$wwwlogs_dir"
  sed -e "s|__WWWROOT__|${wwwroot_dir}|g" \
      "$LOCKLET_ROOT/config/default.conf.tmpl" > /etc/nginx/conf.d/0.default.conf
  [ -f "$wwwroot_dir/default/index.html" ] || cp -f "$LOCKLET_ROOT/config/index.html.tmpl" "$wwwroot_dir/default/index.html"
  chown -R "${www_user}:${www_group}" "$wwwroot_dir" "$wwwlogs_dir"

  # 4) 迁移数据 (源码版 vhost/ssl/rewrite -> 官方布局)
  if [ -n "${DEB_MIGRATE_OLD_PREFIX:-}" ]; then
    local old
    old=$(ls -d "${DEB_MIGRATE_OLD_PREFIX}".bak-* 2>/dev/null | tail -1)
    if [ -n "$old" ]; then
      if [ -d "$old/conf/vhost" ]; then
        find "$old/conf/vhost" -maxdepth 1 -name '*.conf' -exec cp -a {} /etc/nginx/conf.d/ \;
      fi
      [ -d "$old/conf/ssl" ] && cp -a "$old/conf/ssl/." /etc/nginx/ssl/ 2>/dev/null
      [ -d "$old/conf/rewrite" ] && cp -a "$old/conf/rewrite/." /etc/nginx/rewrite/ 2>/dev/null
      rm -f /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/*.dpkg-* 2>/dev/null
      # conf 内的绝对路径改写: 用"原路径"(conf 内容里仍是原始 prefix, 不是 .bak 名)
      sed -i -e "s|${DEB_MIGRATE_OLD_PREFIX}/conf/ssl|/etc/nginx/ssl|g" \
             -e "s|${DEB_MIGRATE_OLD_PREFIX}/conf/rewrite|/etc/nginx/rewrite|g" \
             /etc/nginx/conf.d/*.conf 2>/dev/null
      step_ok "vhost/证书/伪静态 已迁移到 /etc/nginx"
    fi
  fi

  # 5) 启动
  systemctl enable nginx >/dev/null 2>&1
  systemctl daemon-reload
  /usr/sbin/nginx -t
  systemctl restart nginx
  sleep 1
  systemctl is-active nginx >/dev/null 2>&1 || { systemctl status nginx --no-pager | tail -20; log_fatal "nginx 启动失败"; }
  step_ok "nginx (deb) 已启动"

  # 6) 回写路径变量
  set_opt "$LOCKLET_ROOT/options.conf" nginx_sbin "/usr/sbin/nginx"
  set_opt "$LOCKLET_ROOT/options.conf" nginx_conf "/etc/nginx"
  set_opt "$LOCKLET_ROOT/options.conf" nginx_vhost_dir "/etc/nginx/conf.d"
  set_opt "$LOCKLET_ROOT/options.conf" nginx_ssl_dir "/etc/nginx/ssl"
  set_opt "$LOCKLET_ROOT/options.conf" nginx_rewrite_dir "/etc/nginx/rewrite"
}

# deb 版 -> 源码版迁移 (在源码编译前调用): 备份并卸载 deb 包
migrate_deb_to_source() {
  dpkg -s nginx >/dev/null 2>&1 || return 0
  log_info "检测到官方 deb 版 nginx, 备份并切换到源码编译..."
  local ts
  ts=$(date +%Y%m%d%H%M%S)
  SRC_MIGRATE_BACKUP="/root/locklet-deb-backup-${ts}"
  mkdir -p "$SRC_MIGRATE_BACKUP"
  [ -d /etc/nginx/conf.d ] && cp -a /etc/nginx/conf.d "$SRC_MIGRATE_BACKUP/"
  [ -d /etc/nginx/ssl ] && cp -a /etc/nginx/ssl "$SRC_MIGRATE_BACKUP/"
  [ -d /etc/nginx/rewrite ] && cp -a /etc/nginx/rewrite "$SRC_MIGRATE_BACKUP/"
  systemctl stop nginx 2>/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get purge -y nginx nginx-common >/dev/null 2>&1
  step_ok "deb 版已卸载, 备份于 $SRC_MIGRATE_BACKUP"
}

# 源码编译完成后: 恢复 deb 版备份数据
# 注意: 须在 install_nginx_conf 之前调用 (后者写 0.default.conf 并 restart 加载全部配置)
restore_from_deb_backup() {
  [ -n "${SRC_MIGRATE_BACKUP:-}" ] && [ -d "$SRC_MIGRATE_BACKUP" ] || return 0
  local dir="$nginx_vhost_dir"
  mkdir -p "$dir" "$nginx_ssl_dir" "$nginx_rewrite_dir"
  if [ -d "$SRC_MIGRATE_BACKUP/conf.d" ]; then
    find "$SRC_MIGRATE_BACKUP/conf.d" -maxdepth 1 -name '*.conf' -not -name '0.default.conf' -not -name 'default.conf' \
      -exec cp -a {} "$dir/" \;
  fi
  [ -d "$SRC_MIGRATE_BACKUP/ssl" ] && cp -a "$SRC_MIGRATE_BACKUP/ssl/." "$nginx_ssl_dir/" 2>/dev/null
  [ -d "$SRC_MIGRATE_BACKUP/rewrite" ] && cp -a "$SRC_MIGRATE_BACKUP/rewrite/." "$nginx_rewrite_dir/" 2>/dev/null
  rm -f "$dir"/*.dpkg-* 2>/dev/null
  # 绝对路径改写回 oneinstack 布局
  sed -i -e "s|/etc/nginx/ssl|${nginx_ssl_dir}|g" \
         -e "s|/etc/nginx/rewrite|${nginx_rewrite_dir}|g" \
         "$dir"/*.conf 2>/dev/null
  step_ok "deb 版数据已恢复到 ${nginx_conf}"
}
