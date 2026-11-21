#!/bin/bash
# 源码下载 (支持 github 镜像加速 + 断点/重试)

SRC_DIR="${SRC_DIR:-src}"

# url_rewrite <url>: github 镜像改写
url_rewrite() {
  local url="$1"
  if [ -n "$github_mirror" ]; then
    case "$url" in
      https://github.com/*|https://raw.githubusercontent.com/*)
        echo "${github_mirror%/}/${url}"
        ;;
      *) echo "$url" ;;
    esac
  else
    echo "$url"
  fi
}

# src_fetch <url> <dest-file>
src_fetch() {
  local url="$1" dest="$2" real
  [ -s "$dest" ] && { log_info "已存在 $(basename "$dest"), 跳过下载"; return 0; }
  mkdir -p "$(dirname "$dest")"
  real=$(url_rewrite "$url")
  log_info "下载 $(basename "$dest") <- $real"
  for i in 1 2 3; do
    if curl -fL --connect-timeout 15 --retry 2 --progress-bar -o "$dest.tmp" "$real"; then
      mv "$dest.tmp" "$dest"
      step_ok "下载完成: $(basename "$dest") ($(du -h "$dest" | awk '{print $1}'))"
      return 0
    fi
    rm -f "$dest.tmp"
    log_warn "下载失败, 第 ${i} 次重试..."
    sleep 2
  done
  log_fatal "下载失败: $url"
}

# src_unpack <tarball> : 校验并解压到 SRC_DIR (已解压则跳过)
src_unpack() {
  local tarball="$1" dir="${2:-}"
  local base
  base=$(basename "$tarball")
  local name="${base%.tar.gz}"
  name="${name%.tgz}"
  if [ -n "$dir" ] && [ -d "$SRC_DIR/$dir" ]; then
    log_info "已解压 $dir, 跳过"
    return 0
  fi
  # 完整性: gzip -t + tar 列表首项
  gzip -t "$tarball" 2>/dev/null || log_fatal "$base 不是有效的 gzip 文件"
  local first
  first=$(tar -tzf "$tarball" 2>/dev/null | head -1)
  [ -n "$first" ] || log_fatal "$base 不是有效的 tar 包"
  log_info "解压 $base"
  tar -xzf "$tarball" -C "$SRC_DIR"
  step_ok "解压完成"
}
