#!/bin/bash
# lego (ACME 客户端) 安装 + 自动续期 systemd timer

install_lego() {
  if [ -x /usr/local/bin/lego ]; then
    log_info "lego 已安装: $(/usr/local/bin/lego --version 2>/dev/null | head -1)"
  fi

  local arch
  case "$(uname -m)" in
    x86_64)  arch=amd64 ;;
    aarch64) arch=arm64 ;;
    *) log_fatal "不支持的架构: $(uname -m)" ;;
  esac

  src_fetch "https://github.com/go-acme/lego/releases/download/v${lego_version}/lego_v${lego_version}_linux_${arch}.tar.gz" \
    "$SRC_DIR/lego_v${lego_version}_linux_${arch}.tar.gz"

  mkdir -p /tmp/locklet_lego
  tar -xzf "$SRC_DIR/lego_v${lego_version}_linux_${arch}.tar.gz" -C /tmp/locklet_lego
  install -m 0755 "/tmp/locklet_lego/lego" /usr/local/bin/lego
  rm -rf /tmp/locklet_lego
  step_ok "lego 安装到 /usr/local/bin/lego"
  /usr/local/bin/lego --version

  # 续期脚本 + systemd timer (证书目录按安装模式指向 /etc/nginx/ssl 或 /usr/local/nginx/conf/ssl)
  sed -e "s|__NGINX_SSL__|${nginx_ssl_dir}|g" \
      "$LOCKLET_ROOT/config/lego-renew.sh.tmpl" > /usr/local/bin/lego-renew.sh
  chmod 0755 /usr/local/bin/lego-renew.sh

  cp -f "$LOCKLET_ROOT/config/lego-renew.service.tmpl" /etc/systemd/system/lego-renew.service
  cp -f "$LOCKLET_ROOT/config/lego-renew.timer.tmpl"   /etc/systemd/system/lego-renew.timer

  # nginx 自动升级 (deb: apt / source: 重编)
  sed -e "s|__LOCKLET_CONF__|${LOCKLET_ROOT}/options.conf|g" \
      "$LOCKLET_ROOT/config/locklet-upgrade.sh.tmpl" > /usr/local/bin/locklet-upgrade.sh
  chmod 0755 /usr/local/bin/locklet-upgrade.sh
  cp -f "$LOCKLET_ROOT/config/locklet-upgrade.service.tmpl" /etc/systemd/system/locklet-upgrade.service
  cp -f "$LOCKLET_ROOT/config/locklet-upgrade.timer.tmpl"   /etc/systemd/system/locklet-upgrade.timer

  systemctl daemon-reload
  systemctl enable lego-renew.timer >/dev/null 2>&1
  if [ "${auto_upgrade:-y}" = "y" ]; then
    systemctl enable locklet-upgrade.timer >/dev/null 2>&1
    step_ok "定时任务: lego-renew.timer (每天 03:30) + locklet-upgrade.timer (每周日 04:30)"
  else
    systemctl disable locklet-upgrade.timer >/dev/null 2>&1
    step_ok "定时任务: lego-renew.timer (每天 03:30); 自动升级已关闭"
  fi
}
