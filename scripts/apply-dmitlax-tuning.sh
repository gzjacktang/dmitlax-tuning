#!/usr/bin/env bash
set -euo pipefail

# dmitlax 一键网络参数应用脚本
#
# 用法：
#   1. 按需修改下面“可调参数区”
#   2. 执行：./scripts/apply-dmitlax-tuning.sh
#
# 说明：
#   - 脚本会通过 SSH 连接到 VPS，先备份远端旧配置，再应用并固化新参数。
#   - 会使用 SSH 长连接复用，避免短时间反复新建 SSH 连接影响测试判断。
#   - 默认只调 sysctl TCP 参数和 eth0 root fq，不改内核、不改 x-ui。

###############################################################################
# VPS 连接参数
###############################################################################

# VPS 登录用户。
SSH_USER="root"

# VPS IP。dmitlax = 154.21.82.9。
SSH_HOST="154.21.82.9"

# VPS SSH 端口。
SSH_PORT="22282"

# 本机私钥路径。可以改成绝对路径或相对当前目录的路径。
SSH_KEY=".keys_lax/key-nav9zdce.pem"

# SSH 复用连接保存位置。不要放到 git 里。
SSH_CONTROL_DIR=".ssh_mux"

###############################################################################
# TCP/BBR 参数
###############################################################################

# 默认队列算法。BBR 通常配 fq。
DEFAULT_QDISC="fq"

# TCP 拥塞控制算法。当前 dmitlax 使用 BBR3 内核里的 bbr。
TCP_CONGESTION_CONTROL="bbr"

# 空闲后是否重新慢启动：
#   0 = 不重新慢启动，长连接/视频类通常更顺
#   1 = 使用内核默认慢启动行为
TCP_SLOW_START_AFTER_IDLE="0"

# MTU 探测：
#   0 = 关闭，当前 dmitlax 观察更稳
#   1 = 弱探测，遇到路径 MTU 问题时可尝试
#   2 = 总是探测，一般不建议直接用
TCP_MTU_PROBING="0"

# 未发送数据低水位：
#   4294967295 = 基本放开，不主动限制应用写入积压
#   65536/131072/262144 = 更强延迟控制，但可能影响吞吐和起速
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
# 第三个值一般和 RMEM_MAX 保持一致。
TCP_RMEM_MIN="4096"
TCP_RMEM_DEFAULT="131072"
TCP_RMEM_MAX="$RMEM_MAX"

# TCP 自动发送窗口：最小 默认 最大，单位字节。
# 第三个值一般和 WMEM_MAX 保持一致。
TCP_WMEM_MIN="4096"
TCP_WMEM_DEFAULT="16384"
TCP_WMEM_MAX="$WMEM_MAX"

# 网卡收包 backlog，单位是包数量，不是字节。
# 常用档位：512 / 1024 / 2048 / 4096 / 8192。
# 越大越能吃突发，过大可能增加排队延迟。
NETDEV_MAX_BACKLOG="4096"

# 连接队列。通常保持即可，不是当前主要调优旋钮。
SOMAXCONN="8192"
TCP_MAX_SYN_BACKLOG="8192"

# SYN cookies，抗 SYN flood，通常保持 1。
TCP_SYNCOOKIES="1"

###############################################################################
# FQ 队列参数
###############################################################################

# 要应用 FQ 的网卡名。
NETDEV="eth0"

# FQ 总队列包数上限，单位是包数量，不是字节。
# dmitlax 已试过：
#   5000  = 已验证稳定基准
#   10000 = 上传相对好，但 YouTube 略差
#   15000 = 10000 和 20000 中间档
#   20000 = 下载/YouTube 可能更好，但上传更容易变差
FQ_LIMIT="15000"

# FQ 单 flow 包数上限，单位是包数量。
# dmitlax 已试过：
#   64   = 温和
#   100  = 当前更均衡
#   1000 = 很激进，体感速度好但 Speedtest 容易差
FQ_FLOW_LIMIT="100"

###############################################################################
# 脚本主体：一般不用改下面
###############################################################################

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

mkdir -p "$SSH_CONTROL_DIR"
chmod 700 "$SSH_CONTROL_DIR"

SSH_CONTROL_PATH="$ROOT_DIR/$SSH_CONTROL_DIR/%r@%h:%p"
SSH_TARGET="${SSH_USER}@${SSH_HOST}"

SSH_OPTS=(
  -i "$SSH_KEY"
  -p "$SSH_PORT"
  -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=accept-new
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=3
  -o ControlMaster=auto
  -o ControlPersist=10m
  -o ControlPath="$SSH_CONTROL_PATH"
)

echo "==> Connecting to ${SSH_TARGET}:${SSH_PORT} with SSH connection reuse"
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" true

echo "==> Applying sysctl and fq settings on dmitlax"
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" \
  "DEFAULT_QDISC='$DEFAULT_QDISC' \
   TCP_CONGESTION_CONTROL='$TCP_CONGESTION_CONTROL' \
   TCP_SLOW_START_AFTER_IDLE='$TCP_SLOW_START_AFTER_IDLE' \
   TCP_MTU_PROBING='$TCP_MTU_PROBING' \
   TCP_NOTSENT_LOWAT='$TCP_NOTSENT_LOWAT' \
   RMEM_MAX='$RMEM_MAX' \
   WMEM_MAX='$WMEM_MAX' \
   TCP_RMEM_MIN='$TCP_RMEM_MIN' \
   TCP_RMEM_DEFAULT='$TCP_RMEM_DEFAULT' \
   TCP_RMEM_MAX='$TCP_RMEM_MAX' \
   TCP_WMEM_MIN='$TCP_WMEM_MIN' \
   TCP_WMEM_DEFAULT='$TCP_WMEM_DEFAULT' \
   TCP_WMEM_MAX='$TCP_WMEM_MAX' \
   NETDEV_MAX_BACKLOG='$NETDEV_MAX_BACKLOG' \
   SOMAXCONN='$SOMAXCONN' \
   TCP_MAX_SYN_BACKLOG='$TCP_MAX_SYN_BACKLOG' \
   TCP_SYNCOOKIES='$TCP_SYNCOOKIES' \
   NETDEV='$NETDEV' \
   FQ_LIMIT='$FQ_LIMIT' \
   FQ_FLOW_LIMIT='$FQ_FLOW_LIMIT' \
   bash -s" <<'REMOTE_SCRIPT'
set -euo pipefail

stamp="$(date +%Y%m%d-%H%M%S)"

if [ -f /etc/sysctl.d/98-bbr3-balanced.conf ]; then
  cp -a /etc/sysctl.d/98-bbr3-balanced.conf "/etc/sysctl.d/98-bbr3-balanced.conf.bak.${stamp}"
fi

if [ -f /etc/systemd/system/codex-root-fq.service ]; then
  cp -a /etc/systemd/system/codex-root-fq.service "/etc/systemd/system/codex-root-fq.service.bak.${stamp}"
fi

cat > /etc/sysctl.d/98-bbr3-balanced.conf <<EOF
# Managed by apply-dmitlax-tuning.sh
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

cat > /etc/systemd/system/codex-root-fq.service <<EOF
[Unit]
Description=Apply Codex root fq qdisc on ${NETDEV}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/tc qdisc replace dev ${NETDEV} root fq limit ${FQ_LIMIT} flow_limit ${FQ_FLOW_LIMIT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

sysctl --system >/tmp/codex-sysctl-apply.log
/usr/sbin/tc qdisc replace dev "${NETDEV}" root fq limit "${FQ_LIMIT}" flow_limit "${FQ_FLOW_LIMIT}"
systemctl daemon-reload
systemctl enable --now codex-root-fq.service >/tmp/codex-root-fq-enable.log

echo "remote_backup_stamp=${stamp}"
echo "==> Current sysctl"
sysctl \
  net.core.default_qdisc \
  net.ipv4.tcp_congestion_control \
  net.ipv4.tcp_slow_start_after_idle \
  net.ipv4.tcp_mtu_probing \
  net.ipv4.tcp_notsent_lowat \
  net.core.rmem_max \
  net.core.wmem_max \
  net.ipv4.tcp_rmem \
  net.ipv4.tcp_wmem \
  net.core.netdev_max_backlog

echo "==> Current qdisc"
tc qdisc show dev "${NETDEV}"
REMOTE_SCRIPT

echo "==> Done"
