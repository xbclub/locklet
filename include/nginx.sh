#!/bin/bash
# nginx 编译安装 (oneinstack 风格: www 用户 / /usr/local/nginx / /data/wwwroot / /data/wwwlogs)

NGINX_ARGS_FILE="/tmp/locklet_nginx_configure.args"

# 创建 www 运行账户
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

# 准备数据目录
prepare_dirs() {
  mkdir -p "$wwwroot_dir/default" "$wwwlogs_dir" \
           "$nginx_prefix/conf/vhost" "$nginx_prefix/conf/rewrite" "$nginx_prefix/conf/ssl"
  chown -R "${www_user}:${www_group}" "$wwwroot_dir" "$wwwlogs_dir"
  chmod -R 755 "$wwwroot_dir"
  step_ok "创建目录: $wwwroot_dir $wwwlogs_dir"
}

# 模块名 -> configure 参数 (下载第三方源码由 download_sources 统一处理)
module_configure_args() {
  local mods="$1" args="" m
  for m in ${mods//,/ }; do
    case "$m" in
      stub_status)  args="$args --with-http_stub_status_module" ;;
      http_v3)      args="$args --with-http_v3_module" ;;
      sub_module)   args="$args --with-http_sub_module" ;;
      headers_more) args="$args --add-module=../headers-more-nginx-module-${headers_more_version}" ;;
      brotli)       args="$args --add-module=../ngx_brotli" ;;
      *) log_fatal "未知模块: $m (可选: stub_status http_v3 sub_module headers_more brotli)" ;;
    esac
  done
  echo "$args"
}

# 下载所有源码包
download_sources() {
  src_fetch "https://nginx.org/download/nginx-${nginx_version}.tar.gz" "$SRC_DIR/nginx-${nginx_version}.tar.gz"
  src_fetch "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${pcre2_version}/pcre2-${pcre2_version}.tar.gz" "$SRC_DIR/pcre2-${pcre2_version}.tar.gz"
  src_fetch "https://github.com/madler/zlib/releases/download/v${zlib_version}/zlib-${zlib_version}.tar.gz" "$SRC_DIR/zlib-${zlib_version}.tar.gz"
  src_fetch "https://github.com/openssl/openssl/releases/download/openssl-${openssl_version}/openssl-${openssl_version}.tar.gz" "$SRC_DIR/openssl-${openssl_version}.tar.gz"

  src_unpack "$SRC_DIR/nginx-${nginx_version}.tar.gz" "nginx-${nginx_version}"
  src_unpack "$SRC_DIR/pcre2-${pcre2_version}.tar.gz" "pcre2-${pcre2_version}"
  src_unpack "$SRC_DIR/zlib-${zlib_version}.tar.gz" "zlib-${zlib_version}"
  src_unpack "$SRC_DIR/openssl-${openssl_version}.tar.gz" "openssl-${openssl_version}"

  local norm_mods=" ${nginx_modules//,/ } "
  case "$norm_mods" in
    *" headers_more "*)
      src_fetch "https://github.com/openresty/headers-more-nginx-module/archive/refs/tags/v${headers_more_version}.tar.gz" \
        "$SRC_DIR/headers-more-nginx-module-${headers_more_version}.tar.gz"
      src_unpack "$SRC_DIR/headers-more-nginx-module-${headers_more_version}.tar.gz" "headers-more-nginx-module-${headers_more_version}"
      ;;
  esac
  case "$norm_mods" in
    *" brotli "*)
      if [ -d "$SRC_DIR/ngx_brotli/.git" ] || [ -d "$SRC_DIR/ngx_brotli/src" ]; then
        log_info "ngx_brotli 已存在, 跳过克隆"
      else
        local brotli_url
        brotli_url=$(url_rewrite "https://github.com/google/ngx_brotli")
        git clone --recursive --depth 1 "$brotli_url" "$SRC_DIR/ngx_brotli" \
          || log_fatal "克隆 ngx_brotli 失败"
      fi
      ;;
  esac
}

# 编译安装 nginx
install_nginx() {
  cd "$SRC_DIR/nginx-${nginx_version}" || log_fatal "进入 nginx 源码目录失败"

  local extra_args
  extra_args=$(module_configure_args "$nginx_modules")

  # 核心编译参数 = 最小化参数 + 加固 + pcre2/zlib/openssl 源码内置编译 (oneinstack 同款做法)
  # 用数组拼装: cc-opt/ld-opt 带空格, 字符串展开会拆坏
  local -a cfg_args=(
    "--prefix=$nginx_prefix"
    "--user=$www_user"
    "--group=$www_group"
    --with-http_v2_module
    --with-http_ssl_module
    --with-stream
    --with-stream_ssl_preread_module
    --with-stream_ssl_module
    --with-http_gzip_static_module
    --with-http_realip_module
    --with-http_flv_module
    --with-http_mp4_module
    --with-http_addition_module
    --with-threads
    --with-file-aio
    --with-http_auth_request_module
    --with-http_gunzip_module
    --with-stream_realip_module
    "--with-pcre=../pcre2-${pcre2_version}"
    --with-pcre-jit
    "--with-zlib=../zlib-${zlib_version}"
    "--with-openssl=../openssl-${openssl_version}"
    "--with-openssl-opt=no-tests -fPIC"
    "--with-cc-opt=$nginx_cc_opt"
    "--with-ld-opt=$nginx_ld_opt"
  )

  printf '%s\n' "${cfg_args[@]}" > "$NGINX_ARGS_FILE"

  # 官方 nginx 包入口是根目录 ./configure (个别分支/文档写 ./auto/configure, 兼容之)
  local cfg_bin="./configure"
  [ -f "$cfg_bin" ] || cfg_bin="./auto/configure"
  [ -f "$cfg_bin" ] || log_fatal "configure 入口脚本不存在 (./configure)"

  log_info "configure 参数:"
  printf "    %s" "$cfg_bin"; printf ' %s' "${cfg_args[@]}"; printf ' %s\n' "$extra_args"

  "$cfg_bin" "${cfg_args[@]}" $extra_args > /tmp/locklet_nginx_configure.log 2>&1 \
    || { tail -30 /tmp/locklet_nginx_configure.log; log_fatal "configure 失败, 完整日志: /tmp/locklet_nginx_configure.log"; }
  step_ok "configure 成功"

  local nproc
  nproc=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)
  log_info "make -j${nproc} (openssl 编译较慢, 请耐心等待)"
  make -j"$nproc" > /tmp/locklet_nginx_make.log 2>&1 \
    || { tail -30 /tmp/locklet_nginx_make.log; log_fatal "make 失败, 完整日志: /tmp/locklet_nginx_make.log"; }
  step_ok "make 成功"

  make install > /tmp/locklet_nginx_install.log 2>&1 \
    || { tail -30 /tmp/locklet_nginx_install.log; log_fatal "make install 失败"; }
  step_ok "make install 成功 -> $nginx_prefix"
}

# 安装配置文件 / 默认站点 / systemd 服务 / logrotate
install_nginx_conf() {
  local tmpl_dir="$LOCKLET_ROOT/config"
  local norm_mods=" ${nginx_modules//,/ } "
  local brotli_tmp
  brotli_tmp=$(mktemp) || log_fatal "mktemp 失败"
  case "$norm_mods" in
    *" brotli "*)
      cat > "$brotli_tmp" <<'EOF'

    brotli on;
    brotli_comp_level 6;
    brotli_min_length 1k;
    brotli_types text/plain text/css application/javascript application/json application/xml application/xml+rss image/svg+xml font/woff2;
EOF
      ;;
    *) : > "$brotli_tmp" ;;
  esac

  # nginx.conf
  sed -e "s|__WWW_USER__|${www_user}|g" \
      -e "s|__WWWLOGS__|${wwwlogs_dir}|g" \
      -e "s|__WWWROOT__|${wwwroot_dir}|g" \
      -e "s|__NGINX_PREFIX__|${nginx_prefix}|g" \
      -e "/__BROTLI_CONF__/r ${brotli_tmp}" \
      -e "/__BROTLI_CONF__/d" \
      "$tmpl_dir/nginx.conf.tmpl" > "$nginx_prefix/conf/nginx.conf"
  rm -f "$brotli_tmp"

  # 默认站点 (server_name _ 占位, 防 IP 直接访问打到业务 vhost)
  sed -e "s|__WWWROOT__|${wwwroot_dir}|g" \
      "$tmpl_dir/default.conf.tmpl" > "$nginx_prefix/conf/vhost/0.default.conf"

  # 默认首页
  cp -f "$tmpl_dir/index.html.tmpl" "$wwwroot_dir/default/index.html"

  chown -R "${www_user}:${www_group}" "$wwwroot_dir"

  # logrotate (日志轮转)
  if [ -d /etc/logrotate.d ] && [ -f "$tmpl_dir/nginx.logrotate.tmpl" ]; then
    sed -e "s|__WWWLOGS__|${wwwlogs_dir}|g" \
        -e "s|__NGINX_PREFIX__|${nginx_prefix}|g" \
        "$tmpl_dir/nginx.logrotate.tmpl" > /etc/logrotate.d/nginx
  fi

  # systemd
  sed -e "s|__NGINX_PREFIX__|${nginx_prefix}|g" \
      "$tmpl_dir/nginx.service.tmpl" > /etc/systemd/system/nginx.service
  systemctl daemon-reload
  systemctl enable nginx >/dev/null 2>&1
  step_ok "写入 nginx.conf / vhost/0.default.conf / logrotate / systemd unit"

  # 自检
  "$nginx_prefix/sbin/nginx" -t
  systemctl restart nginx
  sleep 1
  systemctl is-active nginx >/dev/null 2>&1 || { systemctl status nginx --no-pager | tail -20; log_fatal "nginx 启动失败"; }
  step_ok "nginx 已启动 (systemd)"
  "$nginx_prefix/sbin/nginx" -v
}
