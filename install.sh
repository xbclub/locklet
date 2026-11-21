#!/bin/bash
####################################################################
# locklet — nginx + lego 一键安装 (oneinstack 设计模式)
#
# 用法:
#   交互安装:  ./install.sh
#   无人值守:  ./install.sh --auto
#   常用参数:
#     --nginx-version  <ver>     指定 nginx 版本 (默认 1.31.9)
#     --nginx-module   <m,m>     附加模块: stub_status http_v3 sub_module headers_more brotli
#     --skip-nginx               跳过 nginx
#     --skip-lego                跳过 lego
#     --mirror <url>             github 下载加速镜像前缀
#     --auto                     使用 options.conf 默认值, 不交互
#
# 路径与 oneinstack 保持一致:
#   /usr/local/nginx      nginx 安装目录
#   /data/wwwroot         网站根目录 (默认站点 /data/wwwroot/default)
#   /data/wwwlogs         日志目录
#   www:www               运行用户
#   /usr/local/bin/lego   ACME 客户端
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

usage() {
  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

need_val() {
  [ "$1" -ge 2 ] || log_fatal "参数 $2 缺少值 (见 --help)"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --auto)          AUTO=1 ;;
    --skip-nginx)    DO_NGINX=0 ;;
    --skip-lego)     DO_LEGO=0 ;;
    --nginx-version) need_val $# "$1"; nginx_version_override="$2"; shift ;;
    --nginx-module)  need_val $# "$1"; nginx_modules_override="$2"; shift ;;
    --mirror)        need_val $# "$1"; github_mirror_override="$2"; shift ;;
    -h|--help)       usage ;;
    *) log_fatal "未知参数: $1 (见 --help)" ;;
  esac
  shift
done

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

check_root
check_os

# ---------------- 交互选择 ----------------
if [ "$AUTO" -eq 0 ]; then
  if [ "$DO_NGINX" -eq 1 ] && [ "$DO_LEGO" -eq 1 ]; then
    printf "\033[33m%s\033[0m" "请选择安装内容:"
    cat <<EOF

  1. 安装 nginx + lego (推荐)
  2. 仅安装 nginx
  3. 仅安装 lego
  4. 退出
EOF
    read -r -p "$(printf '\033[32m%s\033[0m' '请输入选择 [1-4, 默认 1]: ')" choice
    case "${choice:-1}" in
      1) ;;
      2) DO_LEGO=0 ;;
      3) DO_NGINX=0 ;;
      4) exit 0 ;;
      *) log_fatal "无效选择" ;;
    esac
  fi

  if [ "$DO_NGINX" -eq 1 ]; then
    read -r -p "$(printf '\033[32m%s\033[0m' "nginx 版本 [默认 ${nginx_version}]: ")" v
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
    printf "\033[33m%-22s %s\033[0m\n" "nginx 版本:" "$nginx_version" \
                                     "附加模块:" "${nginx_modules:-无}" \
                                     "安装目录:" "$nginx_prefix" \
                                     "网站目录:" "$wwwroot_dir" \
                                     "运行用户:" "$www_user:$www_group"
    confirm "确认开始安装?" y || exit 0
  fi
fi

# 回写 options.conf 供 vhost.sh 使用
sed -i "s|^nginx_version=.*|nginx_version=${nginx_version}|" "$LOCKLET_ROOT/options.conf"
sed -i "s|^nginx_modules=.*|nginx_modules=\"${nginx_modules}\"|" "$LOCKLET_ROOT/options.conf"
[ -n "$github_mirror" ] && sed -i "s|^github_mirror=.*|github_mirror=\"${github_mirror}\"|" "$LOCKLET_ROOT/options.conf"

. "$LOCKLET_ROOT/include/download.sh"

start_ts=$(date +%s)

if [ "$DO_NGINX" -eq 1 ]; then
  . "$LOCKLET_ROOT/include/nginx.sh"
  echo
  log_info "================ nginx 安装 ================"
  install_depend
  create_www_user
  prepare_dirs
  download_sources
  install_nginx
  install_nginx_conf
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
printf "  nginx      : %s\n" "$("$nginx_prefix/sbin/nginx" -v 2>&1)"
printf "  服务       : systemctl {start|stop|reload|restart} nginx\n"
printf "  配置       : %s/conf/nginx.conf\n" "$nginx_prefix"
printf "  vhost 目录 : %s/conf/vhost/\n" "$nginx_prefix"
}
[ "$DO_LEGO" -eq 1 ] && {
printf "  lego       : %s\n" "$(/usr/local/bin/lego --version 2>&1 | head -1)"
printf "  证书目录   : %s/conf/ssl/<域名>/\n" "$nginx_prefix"
printf "  自动续期   : systemctl list-timers | grep lego\n"
}
printf "  网站目录   : %s\n" "$wwwroot_dir"
printf "  日志目录   : %s\n" "$wwwlogs_dir"
echo
log_info "下一步: 添加站点  ./vhost.sh"
