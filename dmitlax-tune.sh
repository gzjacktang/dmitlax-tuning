#!/usr/bin/env bash
set -euo pipefail

# dmitlax VPS 一键调参脚本
#
# 这是给你 SSH 登录 VPS 后直接执行的脚本，不需要本地再 SSH 过去。
#
# 一键运行：
#   bash <(curl -fsSL https://raw.githubusercontent.com/gzjacktang/dmitlax-tuning/main/dmitlax-tune-interactive.sh)
#
# 或者下载后改参数再运行：
#   curl -fsSLO https://raw.githubusercontent.com/gzjacktang/dmitlax-tuning/main/dmitlax-tune-interactive.sh
#   nano dmitlax-tune-interactive.sh
#   bash dmitlax-tune-interactive.sh

###############################################################################
# 可调参数区
###############################################################################

# 网卡名。大多数 VPS 是 eth0；如果不是，先用 ip link 看网卡名。
NETDEV="eth0"

# 是否使用 fq 作为默认队列算法。BBR/BBR3 通常配 fq。
DEFAULT_QDISC="fq"

# TCP 拥塞控制算法。安装 BBR3 后仍然显示为 bbr，区别在 tcp_bbr version。
TCP_CONGESTION_CONTROL="bbr"

# 空闲后是否重新慢启动：
#   0 = 不重新慢启动，视频/长连接通常更顺
#   1 = 使用内核默认慢启动行为
TCP_SLOW_START_AFTER_IDLE="0"

# MTU 探测：
#   0 = 关闭，当前 dmitlax 观察更稳
#   1 = 弱探测，遇到疑似 MTU 黑洞时可试
#   2 = 总是探测，一般不建议直接用
TCP_MTU_PROBING="0"

# 未发送数据低水位：
#   4294967295 = 基本放开，不主动限制应用写入积压
#   65536/131072/262144 = 更强延迟控制，但可能影响起速/吞吐
TCP_NOTSENT_LOWAT="4294967295"

# TCP 接收缓冲最大值，单位字节。
# 常用档位：
#   2097152  = 2MB
#   4194304  = 4MB
#   8388608  = 8MB
#   16777216 = 16MB
#   33554432 = 32MB
#   67108864 = 64MB
RMEM_MAX="8388608"

# TCP 发送缓冲最大值，单位字节。通常和 RMEM_MAX 同档。
WMEM_MAX="8388608"

# TCP 自动接收窗口：最小 默认 最大，单位字节。
TCP_RMEM_MIN="4096"
TCP_RMEM_DEFAULT="131072"
TCP_RMEM_MAX="$RMEM_MAX"

# TCP 自动发送窗口：最小 默认 最大，单位字节。
TCP_WMEM_MIN="4096"
TCP_WMEM_DEFAULT="16384"
TCP_WMEM_MAX="$WMEM_MAX"

# 网卡收包 backlog，单位是包数量，不是字节。
# 常用档位：512 / 1024 / 2048 / 4096 / 8192。
# 越大越能吃突发，过大可能增加排队延迟。
# 默认值采用新加坡 VPS 标准档。
NETDEV_MAX_BACKLOG="2048"

# 连接队列。通常保持即可，不是当前主要调优旋钮。
SOMAXCONN="8192"
TCP_MAX_SYN_BACKLOG="8192"

# SYN cookies，抗 SYN flood，通常保持 1。
TCP_SYNCOOKIES="1"

# FQ 总队列包数上限，单位是包数量，不是字节。
# dmitlax 已试过：
#   5000  = 稳定基准
#   10000 = 新加坡 VPS 标准档
#   15000 = 10000 和 20000 中间档
#   20000 = 下载/YouTube 可能更好，但上传更容易变差
FQ_LIMIT="10000"

# FQ 单 flow 包数上限，单位是包数量。
# dmitlax 已试过：
#   64   = 温和
#   100  = 当前较均衡
#   1000 = 很激进，体感可能好但 Speedtest 容易差
FQ_FLOW_LIMIT="100"

# BBR3 内核安装包。
# XanMod 官方 APT 仓库文档当前推荐 linux-xanmod-x64v3。
# 如果机器 CPU 不支持 x64v3，可改成 linux-xanmod-x64v2 或 linux-xanmod-lts-x64v2。
XANMOD_PACKAGE="linux-xanmod-x64v3"

###############################################################################
# 脚本主体：一般不用改下面
###############################################################################

SYSCTL_FILE="/etc/sysctl.d/98-bbr3-balanced.conf"
FQ_SERVICE="/etc/systemd/system/codex-root-fq.service"
BACKUP_ROOT="/root/dmitlax-tune-backups"

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "请用 root 执行，或用 sudo："
    echo "  sudo bash $0"
    exit 1
  fi
}

pause_line() {
  printf '%*s\n' "${COLUMNS:-80}" '' | tr ' ' '-'
}

ask_yes_no() {
  local prompt="$1"
  local default="${2:-n}"
  local answer

  if [ "$default" = "y" ]; then
    read -r -p "${prompt} [Y/n]: " answer
    answer="${answer:-y}"
  else
    read -r -p "${prompt} [y/N]: " answer
    answer="${answer:-n}"
  fi

  case "$answer" in
    y|Y|yes|YES|Yes|是) return 0 ;;
    *) return 1 ;;
  esac
}

ask_value() {
  local var_name="$1"
  local prompt="$2"
  local default_value="$3"
  local note="${4:-}"
  local answer

  if [ -n "$note" ]; then
    echo "  ${note}"
  fi
  read -r -p "${prompt}，留空默认 ${default_value}: " answer
  printf -v "$var_name" '%s' "${answer:-$default_value}"
}

ask_tuning_values() {
  pause_line
  echo "请输入单项 TCP/FQ 调优参数。"
  echo "留空会使用默认值；默认值采用 MD 中新加坡机器的最优配置：8MB + fq 10000/100 + backlog 2048。"
  pause_line

  ask_value NETDEV "网卡名 NETDEV" "$NETDEV" "要应用 FQ 的网卡名；不确定时先保持 eth0。"
  ask_value DEFAULT_QDISC "默认队列 DEFAULT_QDISC" "$DEFAULT_QDISC" "BBR/BBR3 通常使用 fq。"
  ask_value TCP_CONGESTION_CONTROL "拥塞控制 TCP_CONGESTION_CONTROL" "$TCP_CONGESTION_CONTROL" "BBR3 内核下仍然填写 bbr。"
  ask_value TCP_SLOW_START_AFTER_IDLE "空闲后慢启动 TCP_SLOW_START_AFTER_IDLE" "$TCP_SLOW_START_AFTER_IDLE" "0 = 不重新慢启动；1 = 使用默认慢启动。"
  ask_value TCP_MTU_PROBING "MTU 探测 TCP_MTU_PROBING" "$TCP_MTU_PROBING" "0 = 关闭；1 = 弱探测；2 = 总是探测。"
  ask_value TCP_NOTSENT_LOWAT "未发送低水位 TCP_NOTSENT_LOWAT" "$TCP_NOTSENT_LOWAT" "4294967295 = 基本放开；65536/131072/262144 = 更控延迟。"

  ask_value RMEM_MAX "接收窗口最大 RMEM_MAX" "$RMEM_MAX" "单位字节；8388608 = 8MB。"
  ask_value WMEM_MAX "发送窗口最大 WMEM_MAX" "$WMEM_MAX" "单位字节；通常与 RMEM_MAX 同档。"

  ask_value TCP_RMEM_MIN "tcp_rmem 最小值" "$TCP_RMEM_MIN"
  ask_value TCP_RMEM_DEFAULT "tcp_rmem 默认值" "$TCP_RMEM_DEFAULT"
  ask_value TCP_RMEM_MAX "tcp_rmem 最大值" "$RMEM_MAX" "默认跟 RMEM_MAX 保持一致。"

  ask_value TCP_WMEM_MIN "tcp_wmem 最小值" "$TCP_WMEM_MIN"
  ask_value TCP_WMEM_DEFAULT "tcp_wmem 默认值" "$TCP_WMEM_DEFAULT"
  ask_value TCP_WMEM_MAX "tcp_wmem 最大值" "$WMEM_MAX" "默认跟 WMEM_MAX 保持一致。"

  ask_value NETDEV_MAX_BACKLOG "网卡 backlog NETDEV_MAX_BACKLOG" "$NETDEV_MAX_BACKLOG" "单位是包数量；新加坡标准档为 2048。"
  ask_value SOMAXCONN "连接队列 SOMAXCONN" "$SOMAXCONN"
  ask_value TCP_MAX_SYN_BACKLOG "SYN 队列 TCP_MAX_SYN_BACKLOG" "$TCP_MAX_SYN_BACKLOG"
  ask_value TCP_SYNCOOKIES "SYN cookies TCP_SYNCOOKIES" "$TCP_SYNCOOKIES" "通常保持 1。"

  ask_value FQ_LIMIT "FQ 总队列 FQ_LIMIT" "$FQ_LIMIT" "单位是包数量；新加坡标准档为 10000。"
  ask_value FQ_FLOW_LIMIT "FQ 单 flow 队列 FQ_FLOW_LIMIT" "$FQ_FLOW_LIMIT" "单位是包数量；新加坡标准档为 100。"

  pause_line
  echo "即将应用以下参数："
  cat <<EOF
NETDEV=${NETDEV}
DEFAULT_QDISC=${DEFAULT_QDISC}
TCP_CONGESTION_CONTROL=${TCP_CONGESTION_CONTROL}
TCP_SLOW_START_AFTER_IDLE=${TCP_SLOW_START_AFTER_IDLE}
TCP_MTU_PROBING=${TCP_MTU_PROBING}
TCP_NOTSENT_LOWAT=${TCP_NOTSENT_LOWAT}
RMEM_MAX=${RMEM_MAX}
WMEM_MAX=${WMEM_MAX}
tcp_rmem=${TCP_RMEM_MIN} ${TCP_RMEM_DEFAULT} ${TCP_RMEM_MAX}
tcp_wmem=${TCP_WMEM_MIN} ${TCP_WMEM_DEFAULT} ${TCP_WMEM_MAX}
NETDEV_MAX_BACKLOG=${NETDEV_MAX_BACKLOG}
SOMAXCONN=${SOMAXCONN}
TCP_MAX_SYN_BACKLOG=${TCP_MAX_SYN_BACKLOG}
TCP_SYNCOOKIES=${TCP_SYNCOOKIES}
FQ_LIMIT=${FQ_LIMIT}
FQ_FLOW_LIMIT=${FQ_FLOW_LIMIT}
EOF
  pause_line
}

show_tuning_values() {
  pause_line
  echo "$1"
  cat <<EOF
NETDEV=${NETDEV}
DEFAULT_QDISC=${DEFAULT_QDISC}
TCP_CONGESTION_CONTROL=${TCP_CONGESTION_CONTROL}
TCP_SLOW_START_AFTER_IDLE=${TCP_SLOW_START_AFTER_IDLE}
TCP_MTU_PROBING=${TCP_MTU_PROBING}
TCP_NOTSENT_LOWAT=${TCP_NOTSENT_LOWAT}
RMEM_MAX=${RMEM_MAX}
WMEM_MAX=${WMEM_MAX}
tcp_rmem=${TCP_RMEM_MIN} ${TCP_RMEM_DEFAULT} ${TCP_RMEM_MAX}
tcp_wmem=${TCP_WMEM_MIN} ${TCP_WMEM_DEFAULT} ${TCP_WMEM_MAX}
NETDEV_MAX_BACKLOG=${NETDEV_MAX_BACKLOG}
SOMAXCONN=${SOMAXCONN}
TCP_MAX_SYN_BACKLOG=${TCP_MAX_SYN_BACKLOG}
TCP_SYNCOOKIES=${TCP_SYNCOOKIES}
FQ_LIMIT=${FQ_LIMIT}
FQ_FLOW_LIMIT=${FQ_FLOW_LIMIT}
EOF
  pause_line
}

make_backup() {
  local stamp backup_dir
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup_dir="${BACKUP_ROOT}/${stamp}"
  mkdir -p "$backup_dir"

  uname -a > "${backup_dir}/uname.txt" 2>/dev/null || true
  sysctl -a > "${backup_dir}/sysctl-all.txt" 2>/dev/null || true
  tc qdisc show dev "$NETDEV" > "${backup_dir}/qdisc-${NETDEV}.txt" 2>/dev/null || true
  dpkg -l 'linux-*' > "${backup_dir}/dpkg-linux.txt" 2>/dev/null || true

  [ -f "$SYSCTL_FILE" ] && cp -a "$SYSCTL_FILE" "${backup_dir}/98-bbr3-balanced.conf"
  [ -f "$FQ_SERVICE" ] && cp -a "$FQ_SERVICE" "${backup_dir}/codex-root-fq.service"
  [ -f /etc/apt/sources.list.d/xanmod-release.list ] && cp -a /etc/apt/sources.list.d/xanmod-release.list "${backup_dir}/xanmod-release.list"
  [ -f /etc/apt/keyrings/xanmod-archive-keyring.gpg ] && cp -a /etc/apt/keyrings/xanmod-archive-keyring.gpg "${backup_dir}/xanmod-archive-keyring.gpg"

  echo "$backup_dir"
}

show_status() {
  pause_line
  echo "当前内核："
  uname -a

  pause_line
  echo "当前 BBR/FQ 状态："
  sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc 2>/dev/null || true
  if modinfo tcp_bbr >/dev/null 2>&1; then
    modinfo tcp_bbr 2>/dev/null | sed -n '1,25p' | grep -E '^(filename|version|description):' || true
  else
    echo "tcp_bbr 模块信息不可用；可能是内核未编译或为内置但无 modinfo。"
  fi

  pause_line
  echo "当前 TCP 调参："
  sysctl \
    net.ipv4.tcp_slow_start_after_idle \
    net.ipv4.tcp_mtu_probing \
    net.ipv4.tcp_notsent_lowat \
    net.core.rmem_max \
    net.core.wmem_max \
    net.ipv4.tcp_rmem \
    net.ipv4.tcp_wmem \
    net.core.netdev_max_backlog 2>/dev/null || true

  pause_line
  echo "当前 ${NETDEV} qdisc："
  tc qdisc show dev "$NETDEV" 2>/dev/null || echo "无法读取 ${NETDEV}，请确认 NETDEV 参数。"
  pause_line
}

is_bbr3_now() {
  modinfo tcp_bbr 2>/dev/null | grep -q '^version:[[:space:]]*3'
}

install_bbr3_xanmod() {
  local backup_dir codename
  backup_dir="$(make_backup)"
  echo "已备份当前配置到：${backup_dir}"

  if ! command -v apt-get >/dev/null 2>&1; then
    echo "当前系统没有 apt-get。这个安装流程只支持 Debian/Ubuntu 系。"
    exit 1
  fi

  echo "准备安装 XanMod BBR3 内核包：${XANMOD_PACKAGE}"
  echo "安装后需要重启 VPS，重启后再执行本脚本确认 BBR3 状态。"

  apt-get update
  apt-get install -y wget gpg ca-certificates lsb-release

  mkdir -p /etc/apt/keyrings
  rm -f /etc/apt/keyrings/xanmod-archive-keyring.gpg
  wget -qO - https://dl.xanmod.org/archive.key | gpg --dearmor -o /etc/apt/keyrings/xanmod-archive-keyring.gpg

  codename="$(lsb_release -sc)"
  echo "deb [signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org ${codename} main" > /etc/apt/sources.list.d/xanmod-release.list

  apt-get update
  apt-get install -y "$XANMOD_PACKAGE"

  echo "BBR3 内核安装完成。当前还没切到新内核，需要重启。"
  if ask_yes_no "是否现在重启 VPS？" "n"; then
    reboot
  else
    echo "你可以稍后手动执行：reboot"
  fi
}

apply_tuning() {
  local backup_dir
  backup_dir="$(make_backup)"
  echo "已备份当前配置到：${backup_dir}"

  cat > "$SYSCTL_FILE" <<EOF
# Managed by dmitlax-tune-interactive.sh
net.core.default_qdisc = ${DEFAULT_QDISC}
net.ipv4.tcp_congestion_control = ${TCP_CONGESTION_CONTROL}
net.ipv4.tcp_slow_start_after_idle = ${TCP_SLOW_START_AFTER_IDLE}
net.ipv4.tcp_mtu_probing = ${TCP_MTU_PROBING}
net.ipv4.tcp_notsent_lowat = ${TCP_NOTSENT_LOWAT}
net.core.rmem_max = ${RMEM_MAX}
net.core.wmem_max = ${WMEM_MAX}
net.ipv4.tcp_rmem = ${TCP_RMEM_MIN} ${TCP_RMEM_DEFAULT} ${TCP_RMEM_MAX}
net.ipv4.tcp_wmem = ${TCP_WMEM_MIN} ${TCP_WMEM_DEFAULT} ${TCP_WMEM_MAX}
net.core.somaxconn = ${SOMAXCONN}
net.ipv4.tcp_max_syn_backlog = ${TCP_MAX_SYN_BACKLOG}
net.core.netdev_max_backlog = ${NETDEV_MAX_BACKLOG}
net.ipv4.tcp_syncookies = ${TCP_SYNCOOKIES}
EOF

  cat > "$FQ_SERVICE" <<EOF
[Unit]
Description=Apply dmitlax root fq qdisc on ${NETDEV}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/tc qdisc replace dev ${NETDEV} root fq limit ${FQ_LIMIT} flow_limit ${FQ_FLOW_LIMIT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  sysctl --system >/tmp/dmitlax-sysctl-apply.log
  /usr/sbin/tc qdisc replace dev "$NETDEV" root fq limit "$FQ_LIMIT" flow_limit "$FQ_FLOW_LIMIT"
  systemctl daemon-reload
  systemctl enable --now codex-root-fq.service >/tmp/dmitlax-root-fq-enable.log

  echo "参数已应用并固化。"
  show_status
}

main() {
  need_root

  echo "dmitlax VPS 一键调参脚本"
  echo "默认参数：8MB + fq ${FQ_LIMIT}/${FQ_FLOW_LIMIT} + backlog ${NETDEV_MAX_BACKLOG}"

  show_status

  if is_bbr3_now; then
    echo "检测结果：当前 tcp_bbr version = 3，已经是 BBR3。"
  else
    echo "检测结果：当前未检测到 tcp_bbr version = 3。"
    if ask_yes_no "是否安装 XanMod BBR3 内核？会先备份配置，然后安装 ${XANMOD_PACKAGE}" "n"; then
      install_bbr3_xanmod
    fi
  fi

  if ask_yes_no "是否加载预配置并固化？是=应用 MD 中新加坡机器最优配置，否=进入单项调优" "y"; then
    show_tuning_values "将加载预配置：MD 中新加坡机器最优配置。"
    if ask_yes_no "确认应用以上预配置？" "y"; then
      apply_tuning
    else
      echo "已取消加载预配置。"
    fi
  else
    ask_tuning_values
    if ask_yes_no "确认应用以上单项调优参数？" "y"; then
      apply_tuning
    else
      echo "已取消单项 TCP/FQ 调优。"
    fi
  fi
}

main "$@"
