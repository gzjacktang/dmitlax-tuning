#!/usr/bin/env bash

set -u

GAI_CONF="${GAI_CONF:-/etc/gai.conf}"
STATE_DIR="${STATE_DIR:-/var/lib/ip-stack-priority}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/ip-stack-priority}"
ORIGINAL_BACKUP="$STATE_DIR/gai.conf.original"
ORIGINAL_ABSENT="$STATE_DIR/gai.conf.originally-absent"
BEGIN_MARKER="# BEGIN ip-stack-priority managed block"
END_MARKER="# END ip-stack-priority managed block"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  printf '请使用 root 运行：sudo bash %s\n' "$0" >&2
  exit 1
fi

command -v awk >/dev/null 2>&1 || {
  echo "错误：缺少 awk。" >&2
  exit 1
}

mkdir -p "$STATE_DIR" "$BACKUP_DIR"

ensure_original_backup() {
  [[ -e "$ORIGINAL_BACKUP" || -e "$ORIGINAL_ABSENT" ]] && return 0
  if [[ -e "$GAI_CONF" ]]; then
    cp -a "$GAI_CONF" "$ORIGINAL_BACKUP"
  else
    : >"$ORIGINAL_ABSENT"
    chmod 0600 "$ORIGINAL_ABSENT"
  fi
}

backup_now() {
  local stamp target suffix=0
  stamp=$(date +%Y%m%d-%H%M%S)
  target="$BACKUP_DIR/gai.conf.$stamp"
  while [[ -e $target ]]; do
    suffix=$((suffix + 1))
    target="$BACKUP_DIR/gai.conf.$stamp.$suffix"
  done
  if [[ -e "$GAI_CONF" ]]; then
    cp -a "$GAI_CONF" "$target"
  else
    : >"$target"
    chmod 0644 "$target"
  fi
  printf '已备份到：%s\n' "$target"
}

remove_managed_block() {
  local source=$1 target=$2
  awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" '
    $0 == begin { managed=1; next }
    $0 == end   { managed=0; next }
    !managed    { print }
  ' "$source" >"$target"
}

set_priority() {
  local family=$1 tmp base
  ensure_original_backup
  backup_now
  tmp=$(mktemp)
  base=$(mktemp)
  trap 'rm -f "$tmp" "$base"' RETURN

  [[ -e "$GAI_CONF" ]] || : >"$GAI_CONF"
  remove_managed_block "$GAI_CONF" "$base"
  cp "$base" "$tmp"
  [[ ! -s "$tmp" ]] || printf '\n' >>"$tmp"
  {
    echo "$BEGIN_MARKER"
    if [[ $family == "ipv4" ]]; then
      echo "# 双栈域名优先 IPv4（IPv6 仍可使用）"
      echo "precedence ::ffff:0:0/96  100"
    else
      echo "# 双栈域名优先 IPv6；使用 RFC 6724 的默认优先级"
      echo "precedence ::/0           40"
      echo "precedence ::ffff:0:0/96  35"
    fi
    echo "$END_MARKER"
  } >>"$tmp"
  chmod --reference="$GAI_CONF" "$tmp" 2>/dev/null || chmod 0644 "$tmp"
  chown --reference="$GAI_CONF" "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$GAI_CONF"
  trap - RETURN
  rm -f "$base"
  if [[ $family == "ipv4" ]]; then
    echo "已设置双栈域名连接 IPv4 优先。新启动且遵循 gai.conf 的程序将使用新顺序。"
  else
    echo "已设置双栈域名连接 IPv6 优先。新启动且遵循 gai.conf 的程序将使用新顺序。"
  fi
}

restore_default() {
  local tmp
  backup_now
  if [[ -e "$ORIGINAL_BACKUP" ]]; then
    cp -a "$ORIGINAL_BACKUP" "$GAI_CONF"
    echo "已恢复脚本首次运行前的配置。"
  elif [[ -e "$ORIGINAL_ABSENT" ]]; then
    rm -f "$GAI_CONF"
    echo "已恢复脚本首次运行前的状态（原本不存在 gai.conf）。"
  elif [[ -e "$GAI_CONF" ]]; then
    tmp=$(mktemp)
    remove_managed_block "$GAI_CONF" "$tmp"
    chmod --reference="$GAI_CONF" "$tmp" 2>/dev/null || chmod 0644 "$tmp"
    chown --reference="$GAI_CONF" "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$GAI_CONF"
    echo "未找到原始备份，已移除本脚本管理的配置。"
  else
    echo "当前没有需要恢复的配置。"
  fi
}

probe_family() {
  local family=$1 flag=$2 address=""
  if command -v curl >/dev/null 2>&1; then
    if [[ $family == "IPv4" ]]; then
      address=$(curl "$flag" -fsS --noproxy '*' --connect-timeout 4 --max-time 7 https://api4.ipify.org 2>/dev/null || true)
      [[ $address == *.* && $address != *:* ]] || address=""
    else
      address=$(curl "$flag" -fsS --noproxy '*' --connect-timeout 4 --max-time 7 https://api6.ipify.org 2>/dev/null || true)
      [[ $address == *:* ]] || address=""
    fi
  fi
  if [[ -n $address ]]; then
    printf '%s：可用（出口 IP：%s）\n' "$family" "$address"
    return 0
  fi
  if command -v ip >/dev/null 2>&1 && ip "$flag" route show default 2>/dev/null | grep -q .; then
    printf '%s：检测到默认路由，但公网连通性检测失败或 curl 不可用\n' "$family"
    return 0
  fi
  printf '%s：未检测到可用公网出口\n' "$family"
  return 1
}

show_configured_addresses() {
  local family=$1 flag=$2 addresses=""
  if command -v ip >/dev/null 2>&1; then
    addresses=$(ip -o "$flag" addr show scope global 2>/dev/null | awk '{print $4}' | paste -sd ', ' -)
  fi
  if [[ -n $addresses ]]; then
    printf '%s 网卡全局地址：%s\n' "$family" "$addresses"
  else
    printf '%s 网卡全局地址：未检测到\n' "$family"
  fi
}

show_status() {
  echo
  echo "========== VPS 双栈出口检测 =========="
  show_configured_addresses "IPv4" -4
  show_configured_addresses "IPv6" -6
  probe_family "IPv4" -4 || true
  if probe_family "IPv6" -6; then
    HAS_IPV6=1
  else
    HAS_IPV6=0
  fi
  if [[ -e "$GAI_CONF" ]] && grep -Fq "$BEGIN_MARKER" "$GAI_CONF"; then
    if grep -Eq '^[[:space:]]*precedence[[:space:]]+::ffff:0:0/96[[:space:]]+100([[:space:]]|$)' "$GAI_CONF"; then
      echo "当前脚本模式：双栈域名连接 IPv4 优先"
    else
      echo "当前脚本模式：双栈域名连接 IPv6 优先"
    fi
  else
    echo "当前脚本模式：系统默认"
  fi
}

while true; do
  show_status
  cat <<'MENU'

1. 双栈域名连接以 IPv4 为主（保留 IPv6）
2. 双栈域名连接以 IPv6 为主（保留 IPv4）
3. 备份当前配置
4. 恢复默认/原始配置
0. 退出脚本
MENU
  read -r -p "请选择 [0-4]：" choice
  case $choice in
    1) set_priority ipv4 ;;
    2)
      if [[ $HAS_IPV6 -eq 0 ]]; then
        echo "未检测到可用 IPv6，不能设置 IPv6 优先。"
      else
        set_priority ipv6
      fi
      ;;
    3) ensure_original_backup; backup_now ;;
    4) restore_default ;;
    0) echo "已退出。"; exit 0 ;;
    *) echo "无效选项，请输入 0 到 4。" ;;
  esac
  echo
  read -r -p "按 Enter 返回菜单..." _
done
