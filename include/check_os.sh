#!/bin/bash
# OS 检测与系统依赖安装

check_root() {
  [ "$(id -u)" -eq 0 ] || log_fatal "请使用 root 运行本脚本"
}

check_os() {
  [ -f /etc/os-release ] || log_fatal "/etc/os-release 不存在, 不支持的系统"
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_VERSION="${VERSION_ID:-}"
  OS_PRETTY="${PRETTY_NAME:-unknown}"

  case "$OS_ID" in
    debian)
      case "$OS_VERSION" in
        10|11|12|13) ;;
        *) log_warn "Debian $OS_VERSION 未经测试, 继续尝试" ;;
      esac
      ;;
    ubuntu)
      case "$OS_VERSION" in
        20.*|22.*|24.*) ;;
        *) log_warn "Ubuntu $OS_VERSION 未经测试, 继续尝试" ;;
      esac
      ;;
    *)
      log_warn "未经测试的发行版: $OS_PRETTY (仅支持 apt 系), 继续尝试"
      ;;
  esac
  log_info "操作系统: $OS_PRETTY"
}

install_depend() {
  local pkgs=(gcc g++ make perl curl ca-certificates tar xz-utils git
              jq openssl)
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    wait_apt "安装编译依赖 (apt-get): ${pkgs[*]}"
    apt-get update -y >/dev/null 2>&1 || apt-get update -y
    apt-get install -y "${pkgs[@]}" >/dev/null 2>&1 || apt-get install -y "${pkgs[@]}"
  else
    log_fatal "未找到 apt-get, 仅支持 Debian/Ubuntu"
  fi
  step_ok "编译依赖安装完成"
}
