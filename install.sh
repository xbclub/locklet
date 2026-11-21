#!/bin/bash
####################################################################
# locklet — nginx + lego 一键安装 (oneinstack 设计模式)
#
# 用法:
#   交互安装:  ./install.sh
#   无人值守:  ./install.sh --auto          (默认 = 官方 stable deb 包)
#
# 模式:
#   deb (默认)  nginx.org 官方 deb 包, stable 通道, apt 自动升级
#   source      源码编译 (最小化参数 + 加固 + 可选模块)
#
# 常用参数:
#     --deb                   强制官方 deb 包模式
#     --source                强制源码编译模式
#     --channel <stable|mainline>  deb 仓库通道 (默认 stable)
#     --nginx-version <ver>   指定源码版本 (隐含 --source)
#     --nginx-module  <m,m>   附加模块: stub_status http_v3 sub_module headers_more brotli
#     --skip-conf             升级重编时保留现有 nginx.conf
#     --no-auto-upgrade       不部署每周自动升级 timer
#     --skip-nginx / --skip-lego / --mirror <url> / --auto  同旧版
#
# 路径:
#   deb 模式    /usr/sbin/nginx + /etc/nginx (conf.d 为 vhost), 官方包布局
#   source 模式 /usr/local/nginx (oneinstack 布局), vhost: conf/vhost/
#   两模式共用  /data/wwwroot 网站目录, /data/wwwlogs 日志, www 用户,
#               证书: <conf>/ssl/<域名>/, /usr/local/bin/lego
####################################################################
set -u

LOCKLET_ROOT="$(cd "$(dirname "$0")" && pwd)"
export LOCKLET_ROOT
SRC_DIR="$LOCKLET_ROOT/src"
export SRC_DIR

. "$LOCKLET_ROOT/include/common.sh"
. "$LOCKLET_ROOT/include/check_os.sh"

AUTO=0
DO_NGINX=1
DO_LEGO=1
SKIP_CONF=0
MODE_OVERRIDE=""

usage() {
  sed -n '2,/^#\{4,\}$/p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

need_val() {
  [ "$1" -ge 2 ] || log_fatal "参数 $2 缺少值 (见 --help)"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --auto)          AUTO=1 ;;
    --deb)           MODE_OVERRIDE=deb ;;
    --source)        MODE_OVERRIDE=source ;;
    --channel)       need_val $# "$1"; nginx_channel_override="$2"; shift ;;
    --skip-nginx)    DO_NGINX=0 ;;
    --skip-lego)     DO_LEGO=0 ;;
    --skip-conf)     SKIP_CONF=1 ;;
    --no-auto-upgrade) auto_upgrade_override=n ;;
    --nginx-version) need_val $# "$1"; nginx_version_override="$2"; shift ;;
    --nginx-module)  need_val $# "$1"; nginx_modules_override="$2"; shift ;;
    --mirror)        need_val $# "$1"; github_mirror_override="$2"; shift ;;
    -h|--help)       usage ;;
    *) log_fatal "未知参数: $1 (见 --help)" ;;
  esac
  shift
done
export SKIP_CONF

clear
printf "\033[32m"
cat <<'EOF'
+--------------------------------------------------+
|        locklet : nginx + lego one-click          |
|           (oneinstack-style installer)           |
+--------------------------------------------------+
EOF
printf "\033[0m\n"

load_options "$LOCKLET_ROOT/options.conf"
nginx_version="${nginx_version_override:-$nginx_version}"
nginx_modules="${nginx_modules_override:-$nginx_modules}"
github_mirror="${github_mirror_override:-$github_mirror}"
nginx_channel="${nginx_channel_override:-$nginx_channel}"

# 模式解析: 显式参数 > 指定版本/模块 > options.conf 默认 (deb)
if [ -n "$MODE_OVERRIDE" ]; then
  install_mode="$MODE_OVERRIDE"
elif [ -n "${nginx_version_override:-}${nginx_modules_override:-}" ]; then
  install_mode=source
fi

check_root
check_os

# ---------------- 交互选择 ----------------
mode_from_cli=0
if [ -n "$MODE_OVERRIDE" ] || [ -n "${nginx_version_override:-}" ] || [ -n "${nginx_modules_override:-}" ]; then
  mode_from_cli=1
fi

if [ "$AUTO" -eq 0 ] && [ "$DO_NGINX" -eq 1 ]; then
  if [ "$mode_from_cli" -eq 0 ]; then
    printf "\033[33m%s\033[0m" "nginx 安装模式:"
    cat <<EOF

  1. 官方 stable deb 包 (nginx.org 源, 自动升级)  [推荐]
  2. 源码编译 (最小化参数 + 加固, 可选模块)
EOF
    read -r -p "$(printf '\033[32m%s\033[0m' '请输入选择 [1-2, 默认 1]: ')" choice
    case "${choice:-1}" in
      1) install_mode=deb ;;
      2) install_mode=source ;;
      *) log_fatal "无效选择" ;;
    esac
  fi

  if [ "$install_mode" = "deb" ] && [ -z "${nginx_channel_override:-}" ]; then
    read -r -p "$(printf '\033[32m%s\033[0m' "仓库通道 stable/mainline [默认 ${nginx_channel}]: ")" ch
    [ -n "$ch" ] && nginx_channel="$ch"
  fi
fi

if [ "$AUTO" -eq 0 ] && [ "$install_mode" = "source" ] && [ "$DO_NGINX" -eq 1 ]; then
  read -r -p "$(printf '\033[32m%s\033[0m' "nginx 源码版本 [默认 ${nginx_version}]: ")" v
  [ -n "$v" ] && nginx_version="$v"

  printf "\033[33m%s\033[0m\n" "附加编译模块 (最小化参数之外, 空格分隔序号, 回车跳过):"
  cat <<EOF

  1. http_stub_status_module   状态监控
  2. http_v3_module            QUIC / HTTP3
  3. http_sub_module           响应内容替换
  4. headers-more              更多 header 操作
  5. brotli                    google brotli 压缩 (需要 git)
EOF
  read -r -p "选择 [例如: 1 2]: " mods
  picked=""
  for m in $mods; do
    case "$m" in
      1) picked="${picked}stub_status " ;;
      2) picked="${picked}http_v3 " ;;
      3) picked="${picked}sub_module " ;;
      4) picked="${picked}headers_more " ;;
      5) picked="${picked}brotli " ;;
    esac
  done
  nginx_modules="${picked:+${picked% }}"
  [ -n "$nginx_modules" ] && log_info "附加模块: $nginx_modules"

  echo
  printf "\033[33m%-22s %s\033[0m\n" "安装模式:" "源码编译" \
                                   "nginx 版本:" "$nginx_version" \
                                   "附加模块:" "${nginx_modules:-无}" \
                                   "安装目录:" "$nginx_prefix" \
                                   "网站目录:" "$wwwroot_dir" \
                                   "运行用户:" "$www_user:$www_group"
  confirm "确认开始安装?" y || exit 0
fi

# ---------------- 回写 options.conf ----------------
OC="$LOCKLET_ROOT/options.conf"
[ -n "$github_mirror" ] && set_opt "$OC" github_mirror "\"$github_mirror\""
set_opt "$OC" locklet_dir "\"$LOCKLET_ROOT\""

if [ "$DO_NGINX" -eq 1 ]; then
  set_opt "$OC" install_mode "$install_mode"
  set_opt "$OC" nginx_channel "$nginx_channel"
  set_opt "$OC" nginx_version "$nginx_version"
  set_opt "$OC" nginx_modules "\"$nginx_modules\""
  set_opt "$OC" auto_upgrade "${auto_upgrade_override:-${auto_upgrade:-y}}"

  # source 模式路径回写 (deb 模式在 nginx_deb.sh 内回写官方布局)
  if [ "$install_mode" = "source" ]; then
    set_opt "$OC" nginx_sbin "$nginx_prefix/sbin/nginx"
    set_opt "$OC" nginx_conf "$nginx_prefix/conf"
    set_opt "$OC" nginx_vhost_dir "$nginx_prefix/conf/vhost"
    set_opt "$OC" nginx_ssl_dir "$nginx_prefix/conf/ssl"
    set_opt "$OC" nginx_rewrite_dir "$nginx_prefix/conf/rewrite"
  fi
fi

# 重新加载最终路径
load_options "$OC"

. "$LOCKLET_ROOT/include/download.sh"

start_ts=$(date +%s)

if [ "$DO_NGINX" -eq 1 ]; then
  echo
  log_info "================ nginx 安装 ($install_mode) ================"
  create_www_user

  if [ "$install_mode" = "deb" ]; then
    . "$LOCKLET_ROOT/include/nginx_deb.sh"
    install_depend_deb
    migrate_from_source
    install_nginx_deb            # 内部回写 /etc/nginx 布局路径
    load_options "$OC"           # 刷新路径变量
    prepare_dirs
  else
    . "$LOCKLET_ROOT/include/nginx.sh"
    . "$LOCKLET_ROOT/include/nginx_deb.sh"
    migrate_deb_to_source
    prepare_dirs
    install_depend
    download_sources
    install_nginx
    restore_from_deb_backup     # 恢复 vhost/ssl/rewrite (先于 conf 步骤, restart 一次性加载)
    install_nginx_conf
  fi
  install_upgrade_timer
fi

if [ "$DO_LEGO" -eq 1 ]; then
  . "$LOCKLET_ROOT/include/lego.sh"
  echo
  log_info "================ lego 安装 ================="
  install_lego
fi

end_ts=$(date +%s)
echo
printf "\033[32m"
cat <<EOF
+--------------------------------------------------+
|                 安装完成!                        |
+--------------------------------------------------+
EOF
printf "\033[0m"
printf "  耗时       : %s\n" "$((end_ts - start_ts))s"
[ "$DO_NGINX" -eq 1 ] && {
printf "  模式       : %s (%s)\n" "$install_mode" "$nginx_channel"
printf "  nginx      : %s\n" "$("$nginx_sbin" -v 2>&1)"
printf "  服务       : systemctl {start|stop|reload|restart} nginx\n"
printf "  配置       : %s/nginx.conf\n" "$nginx_conf"
printf "  vhost 目录 : %s\n" "$nginx_vhost_dir"
}
[ "$DO_LEGO" -eq 1 ] && {
printf "  lego       : %s\n" "$(/usr/local/bin/lego --version 2>&1 | head -1)"
printf "  证书目录   : %s/<域名>/\n" "$nginx_ssl_dir"
printf "  自动续期   : systemctl list-timers | grep -E 'lego|upgrade'\n"
}
printf "  网站目录   : %s\n" "$wwwroot_dir"
printf "  日志目录   : %s\n" "$wwwlogs_dir"
echo
log_info "下一步: 添加站点  ./vhost.sh"
