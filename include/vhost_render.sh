#!/bin/bash
# locklet vhost 配置渲染与 nginx reload

nginx_apply() { # 写入后校验并 reload; 失败返回 1 (调用方负责回滚)
  if ! "$NGINX_SBIN" -t 2>&1; then
    log_error "nginx -t 校验失败"
    return 1
  fi
  systemctl reload nginx && step_ok "nginx 已 reload"
}

nginx_reload_only() { "$NGINX_SBIN" -t >/dev/null 2>&1 && systemctl reload nginx; }

# 检测 nginx 是否编译了 http_v3_module (可由 ENABLE_HTTP3=0|1 显式覆盖)
has_http_v3() {
  if [ -n "${ENABLE_HTTP3:-}" ]; then
    [ "$ENABLE_HTTP3" = "1" ]
    return
  fi
  [ -x "${NGINX_SBIN:-}" ] && "$NGINX_SBIN" -V 2>&1 | grep -q "http_v3_module"
}

# ---------------- 配置渲染 ----------------
access_log_line() { # $1 main_domain, $2 y/n
  if [ "$2" = "y" ]; then
    echo "    access_log $wwwlogs_dir/${1}_nginx.log combined;"
  else
    echo "    access_log off;"
  fi
}

static_blocks() { # $1 hotlink y/n, $2 referers
  if [ "$1" = "y" ]; then
    cat <<'EOF'
    location ~ .*\.(wma|wmv|asf|mp3|mmf|zip|rar|jpg|gif|png|swf|flv|ico)$ {
        valid_referers none blocked server_names __REFERERS__;
        if ($invalid_referer) {
            return 403;
        }
        expires 30d;
        access_log off;
    }
EOF
  else
    cat <<'EOF'
    location ~ .*\.(js|css)?$ {
        expires 12h;
        access_log off;
    }

    location ~ .*\.(gif|jpg|jpeg|png|bmp|swf|flv|ico)$ {
        expires 30d;
        access_log off;
    }
EOF
  fi
}

render_sed() { # 公共占位符替换: $1=domains $2=accesslog-line $3=webroot $4=main
  sed -e "s|__DOMAINS__|$1|g" \
      -e "s|__ACCESS_LOG__|$2|g" \
      -e "s|__WEBROOT__|$3|g" \
      -e "s|__MAINDOMAIN__|$4|g"
}

http_server_block() { # 80 端口站点
  cat <<'EOF'
server {
    listen 80;
    listen [::]:80;
    server_name __DOMAINS__;
__ACCESS_LOG__
    root __WEBROOT__;
    index index.html index.htm;

    include rewrite/__MAINDOMAIN__.conf;

    location ^~ /.well-known/acme-challenge/ {
        default_type text/plain;
    }

__STATIC_BLOCKS__
    location ~ /\. {
        deny all;
    }
}
EOF
}

redirect_80_block() { # 80 仅保留 acme 验证 + 301
  cat <<'EOF'
server {
    listen 80;
    listen [::]:80;
    server_name __DOMAINS__;
    access_log off;

    location ^~ /.well-known/acme-challenge/ {
        default_type text/plain;
        root __WEBROOT__;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}
EOF
}

https_server_block() { # 443 站点 (Mozilla Intermediate TLS 配置, 自动支持 HTTP/3)
  local h3_listen="" h3_header=""
  if has_http_v3; then
    h3_listen=$'    listen 443 quic;\n    listen [::]:443 quic;\n'
    h3_header=$'    add_header Alt-Svc \'h3=":443"; ma=86400\' always;\n'
  fi
  cat <<EOF
server {
    listen 443 ssl;
    listen [::]:443 ssl;
${h3_listen}    http2 on;
    server_name __DOMAINS__;
__ACCESS_LOG__
    root __WEBROOT__;
    index index.html index.htm;

    ssl_certificate __SSL_CRT__;
    ssl_certificate_key __SSL_KEY__;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
${h3_header}
    include rewrite/__MAINDOMAIN__.conf;

    location ^~ /.well-known/acme-challenge/ {
        default_type text/plain;
    }

__STATIC_BLOCKS__
    location ~ /\. {
        deny all;
    }
}
EOF
}

# ---------------- vhost 落盘 ----------------
write_rewrite_conf() { # $1 main_domain $2 rewrite_name
  local src="$LOCKLET_ROOT/config/rewrite/$2.conf"
  [ -f "$src" ] || log_fatal "伪静态模板不存在: $2"
  cp -f "$src" "$REWRITE_DIR/$1.conf"
}

# 渲染 vhost 并输出到 stdout; 多行静态/防盗链块用 sed r 命令注入 (跨 awk 实现可移植)
emit_vhost() { # $1=模式 http|ssl|redirect , 其余变量来自全局
  local mode="$1"
  local refs="" d
  for d in "${DOMAINS_ARR[@]}"; do refs="$refs *.$d $d"; done
  refs="${refs# }"

  local tmpb
  tmpb=$(mktemp) || log_fatal "mktemp 失败"
  static_blocks "$HOTLINK" "$refs" | sed "s|__REFERERS__|$refs|g" > "$tmpb"

  local head
  case "$mode" in
    http)     head=$(http_server_block) ;;
    ssl)      head=$(https_server_block) ;;
    redirect) head=$(redirect_80_block) ;;
  esac

  printf '%s\n' "$head" \
    | render_sed "$SERVER_NAMES" "$(access_log_line "$MAIN" "$ACCESSLOG")" "$WEBROOT" "$MAIN" \
    | sed -e "s|__SSL_CRT__|${SSL_CRT:-}|g" -e "s|__SSL_KEY__|${SSL_KEY:-}|g" \
          -e "/__STATIC_BLOCKS__/r ${tmpb}" -e "/__STATIC_BLOCKS__/d"
  rm -f "$tmpb"
}

render_ssl_vhost() { # 用 ssl 版配置替换 http vhost
  local out="$VHOST_DIR/$MAIN.conf"
  cp -f "$out" "$out.bak"
  {
    emit_vhost ssl
    if [ "$FORCE_HTTPS" = "y" ]; then
      echo
      emit_vhost redirect
    else
      echo
      emit_vhost http
    fi
  } > "$out"
  if ! nginx_apply; then
    mv -f "$out.bak" "$out"; nginx_reload_only
    log_fatal "ssl vhost 校验失败, 已回滚 http 版本"
  fi
  rm -f "$out.bak"
  step_ok "https vhost 已上线: $out"
}
