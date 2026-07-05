# VPS 线路优化记录

本文整理本轮 VPS 线路优化的经验，主要面向 VLESS/Reality 节点，场景是：

```text
中国武汉本机 -> VPS -> 目标网站/Reality 出站
```

## 总原则

- 不同地区的 VPS 不要套同一套参数。
- 调优要以实际客户端体验为准，尤其是 VLESS/Reality 的速度、稳定性、断流和 EOF。
- 测速和巡检优先使用 SSH 长连接复用，避免短时间反复新建 SSH 连接导致服务端限流或握手失败。
- 先确认节点配置和 target/SNI 正常，再判断 TCP/BBR 参数。
- 一次只改少量参数，改完保留备份，用户实测反馈后再继续。

## 154.21.82.9 LAX 经验

154 是洛杉矶方向，武汉到 VPS 跨太平洋，RTT 更高，长距离链路更容易受 TCP 窗口和 pacing 影响。

2026-07-05 单独重调：用户反馈前面 FQ 参数可能不准确，先按 45 新加坡节点的标准档在 154 上试一版，用于独立观察。随后用户反馈基准版本偏温柔，试过 16MB 中激进档后反馈更差，因此继续反向试比基准更温和的档位。`4MB + fq 5000/64` 反馈很好；再降到 `2MB + fq 2500/64` 后不如上一版。后续临时试探 `fq 8000/64` 后用户要求固化。随后用户要求回滚到 BBR + root FQ 最原始状态，已停用自定义 TCP 调参文件，仅保留 `99-bbr.conf` 的 `default_qdisc=fq` 和 `tcp_congestion_control=bbr`，root FQ 使用默认参数。

此前激进组合策略：先保留 `4MB` TCP 窗口，只把 `eth0 root fq` 从 `limit 5000 flow_limit 64` 提到 `limit 20000 flow_limit 1000`；随后用户要求 TCP 窗口基线也激进一点，因此把 TCP 窗口从 `4MB` 提到 `8MB`，并把 `netdev_max_backlog` 从 `1024` 提到 `2048`。用户反馈 `8MB + fq 20000/1000` 的 YouTube 比之前好，但 Speedtest 变差，因此曾收敛为 `8MB + fq 10000/100`。随后继续把 TCP 窗口推到 `16MB`，FQ 保持 `10000/100`，再按用户要求回到 `8MB`。用户反馈 `fq 10000/100` 速度不如激进档，但 `fq 20000/1000` 的 Speedtest 不行；`fq 20000/100` 下载好一些但上传差，尤其是 `limit 20000` 档位。降回 `10000/100` 后 YouTube 又差一点，因此试过 `8MB + fq 15000/100 + netdev_backlog 4096` 作为中间点。2026-07-05 用户自行通过脚本切回 `4MB + fq 5000/64 + backlog 1024`，反馈速度很好；随后又临时测试 `fq 20000/64`、`10000/64`、`8000/64`，并短暂固化 `4MB + fq 8000/64 + backlog 1024`。当前已按用户要求回滚到 BBR + root FQ 原始状态。

已验证调优档：

```text
kernel = 6.18.37-x64v3-xanmod1
tcp_bbr version = 3
tcp_congestion_control = bbr
default_qdisc = fq
eth0 qdisc = root fq limit 8000 flow_limit 64
tcp_slow_start_after_idle = 0
tcp_mtu_probing = 0
tcp_notsent_lowat = 4294967295
rmem_max/wmem_max = 4194304
tcp_rmem = 4096 131072 4194304
tcp_wmem = 4096 16384 4194304
netdev_max_backlog = 1024
```

当前运行档：

```text
kernel = 6.18.37-x64v3-xanmod1
tcp_bbr version = 3
tcp_congestion_control = bbr
default_qdisc = fq
eth0 qdisc = root fq limit 10000 flow_limit 100
tcp_slow_start_after_idle = 1
tcp_mtu_probing = 0
tcp_notsent_lowat = 4294967295
rmem_max/wmem_max = 212992
tcp_rmem = 4096 131072 6291456
tcp_wmem = 4096 16384 4194304
netdev_max_backlog = 1000
```

历史 16MB 窗口试验档：

```text
kernel = 6.18.37-x64v3-xanmod1
tcp_bbr version = 3
tcp_congestion_control = bbr
default_qdisc = fq
eth0 qdisc = root fq limit 10000 flow_limit 100
tcp_slow_start_after_idle = 0
tcp_mtu_probing = 0
tcp_notsent_lowat = 4294967295
rmem_max/wmem_max = 16777216
tcp_rmem = 4096 131072 16777216
tcp_wmem = 4096 16384 16777216
netdev_max_backlog = 4096
```

持久化：

```text
/etc/sysctl.d/98-bbr3-balanced.conf.disabled.20260705-123506
/etc/sysctl.d/99-bbr.conf
/etc/systemd/system/codex-root-fq.service
tc qdisc replace dev eth0 root fq
```

最新回滚确认：

```text
2026-07-05
rollback backup_stamp = 20260705-123506
codex-root-fq.service = enabled / active
98-bbr3-balanced.conf = disabled
```

本轮验证结论：

- `16MB + fq 10000/100`：比基准更差，偏激进。
- `8MB + fq 10000/100`：可作为新加坡标准迁移基准，但对 dmitlax 偏温柔且不是最佳点。
- `4MB + fq 5000/64`：历史调优档，反馈很好。
- `4MB + fq 8000/64`：历史调优档，曾短暂固化，后续已按用户要求回滚。
- `BBR + root fq 默认参数`：当前运行档。
- `2MB + fq 2500/64`：更温和但不如 4MB 档。
- `4MB + fq 20000/1000`：最激进 FQ 单变量试验档。
- `8MB + fq 20000/1000`：YouTube 比之前好，但 Speedtest 变差。
- `8MB + fq 10000/100 + backlog 4096`：从 `limit 20000` 降回后，YouTube 也差一点。
- `8MB + fq 20000/1000 + backlog 4096`：体感速度好，但 Speedtest 不行。
- `8MB + fq 20000/100 + backlog 4096`：下载好一些，但上传差，尤其 `limit 20000` 档位不适合上传。
- `8MB + fq 15000/100 + backlog 4096`：曾作为 `10000` 和 `20000` 之间的折中点。
- `16MB + fq 10000/100`：历史 16MB 窗口试验档，整体不如 4MB 最佳档。

回滚参考备份：

```text
/etc/systemd/system/codex-root-fq.service.bak.20260705-091604
/etc/systemd/system/codex-root-fq.service.bak.20260705-090656
/etc/systemd/system/codex-root-fq.service.bak.20260705-090103
/etc/sysctl.d/98-bbr3-balanced.conf.bak.20260705-084416
/etc/sysctl.d/98-bbr3-balanced.conf.bak.20260705-084046
/etc/sysctl.d/98-bbr3-balanced.conf.bak.20260705-083725
/etc/systemd/system/codex-root-fq.service.bak.20260705-084001
/etc/systemd/system/codex-root-fq.service.bak.20260705-083625
/etc/sysctl.d/98-bbr3-balanced.conf.bak.20260705-045504
/etc/sysctl.d/98-bbr3-balanced.conf.bak.20260705-044835
/etc/sysctl.d/98-bbr3-balanced.conf.bak.20260705-045154
/etc/sysctl.d/98-bbr3-balanced.conf.bak.20260705-033543
/etc/sysctl.d/98-bbr3-balanced.conf.bak.20260705-033036
```

上一版稳定方案如下，暂作为回滚参考：

最终稳定方案：

```text
kernel = 6.18.37-x64v3-xanmod1
tcp_congestion_control = bbr
default_qdisc = fq
tcp_bbr version = 3
```

BBR3 v2 调优：

```text
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = 262144
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_syncookies = 1
```

效果：

- 比回滚普通 BBR 后更好。
- v2 比第一版更稳定。
- 适合高 RTT、跨境长距离、需要更大 TCP 窗口的场景。

Reality target 调整：

```text
target = www.ucla.edu:443
serverNames = www.ucla.edu
sni = www.ucla.edu
```

注意：

- `target` 要带 `:443`。
- `serverNames` 和客户端 `sni` 不带端口。
- 需要改 x-ui 数据库源头，单改 `/usr/local/x-ui/bin/config.json` 会被 x-ui 重写。

## dmitTOKYO / 191.222.212.108 东京品川经验

dmitTOKYO 是 191.222.212.108，东京品川方向，武汉到东京链路更近，RTT 比 LAX 低很多。早期测试说明 Joey BBR3 7.1.2 不适合；2026-07-05 重新按“FQ 参数不变”原则启用 XanMod LTS BBR3 复测后仍不理想，已回退到 Debian 6.1 普通 BBR。

尝试过的 BBR3 内核：

```text
kernel = 7.1.2-joeyblog-bbrv3
tcp_bbr version = 3
```

结果：

- 同样 VLESS/Reality 配置下，BBR3 速度明显更差。
- 调大窗口、切吞吐版、改 FQ root 都没有改善。
- 回到 Debian 6.1 普通 BBR 后速度大幅增加。

2026-07-05 重新启用 BBR3 测试：

```text
kernel = 6.18.38-x64v3-xanmod1
tcp_bbr version = 3
tcp_congestion_control = bbr
```

原则：

- FQ/TCP 参数保持 dmitTOKYO 当前最优混合档不变。
- 只切内核到 XanMod LTS x64v3，用于观察 BBR3 是否改善。
- XanMod APT 源已添加，包为 `linux-xanmod-lts-x64v3`。
- 用户反馈 BBR3 不行，已将 GRUB 默认启动项回退到 `6.1.0-21-amd64`。
- XanMod 内核保留在系统中，但不作为默认启动项。

2026-07-05 重新按用户基线测试后的要求，dmitTOKYO 改为普通 BBR + root FQ 方案，不再沿用 `mq + fq` 方案。随后因东京低 RTT 场景不需要过于激进的吞吐参数，逐步收敛测试后，当前固定在 `limit 2500 / flow_limit 100 / 16MB / notsent 65536` 混合档，记录为 dmitTOKYO 当前最优配置，并计划长期观察两天。

排障备注：

- 2026-07-05 曾出现“VPS 速度很慢”的假象，复查服务器端内核、BBR、root FQ、x-ui/xray、网卡 drop/error 均正常。
- 最终确认原因是本地路由器双 WAN 自动 QoS 把流量切到另一条较差线路，不是 dmitTOKYO 参数问题。
- 后续若 dmitTOKYO 突然变慢，先检查本地路由器 WAN 出口、QoS/分流策略，再调整 VPS 参数。

dmitTOKYO 当前最优配置：

```text
kernel = 6.1.0-21-amd64
tcp_bbr = Debian 6.1 official BBR
tcp_congestion_control = bbr
default_qdisc = fq
eth0 qdisc = root fq limit 2500 flow_limit 100
tcp_slow_start_after_idle = 0
tcp_mtu_probing = 1
tcp_notsent_lowat = 65536
rmem_max/wmem_max = 16777216
tcp_rmem/tcp_wmem max = 16777216
netdev_max_backlog = 4096
```

持久化文件：

```text
/etc/sysctl.d/zz-codex-bbr-fq-tuning.conf
/etc/systemd/system/codex-root-fq.service
```

### dmitTOKYO BBR + root FQ 档位记录

本轮实测后，`5000/100 + 16MB` 的 YouTube connecting 最快，`2500/64 + 8MB` 的 Speedtest 更快但 YouTube 不如前者。当前固定为混合档：保留 16MB 和 `notsent_lowat = 65536`，把 FQ limit 降到 2500、flow_limit 保持 100。该档 Speedtest 更好，YouTube 只细微变差，适合长期观察。

上一档，偏吞吐：

```text
eth0 root fq = limit 10000 flow_limit 100
tcp_slow_start_after_idle = 0
tcp_mtu_probing = 1
tcp_notsent_lowat = 131072
rmem_max/wmem_max = 33554432
tcp_rmem = 4096 87380 33554432
tcp_wmem = 4096 65536 33554432
netdev_max_backlog = 8192
```

YouTube 优先档：

```text
eth0 root fq = limit 5000 flow_limit 100
tcp_slow_start_after_idle = 0
tcp_mtu_probing = 1
tcp_notsent_lowat = 65536
rmem_max/wmem_max = 16777216
tcp_rmem = 4096 87380 16777216
tcp_wmem = 4096 65536 16777216
netdev_max_backlog = 4096
```

当前固定混合档：

```text
eth0 root fq = limit 2500 flow_limit 100
tcp_slow_start_after_idle = 0
tcp_mtu_probing = 1
tcp_notsent_lowat = 65536
rmem_max/wmem_max = 16777216
tcp_rmem = 4096 87380 16777216
tcp_wmem = 4096 65536 16777216
netdev_max_backlog = 4096
```

更温和历史档：

```text
eth0 root fq = limit 2500 flow_limit 64
tcp_slow_start_after_idle = 0
tcp_mtu_probing = 1
tcp_notsent_lowat = 32768
rmem_max/wmem_max = 8388608
tcp_rmem = 4096 87380 8388608
tcp_wmem = 4096 65536 8388608
netdev_max_backlog = 2048
```

dmitTOKYO 的网卡特征：

```text
virtio
numtxqueues = 2
numrxqueues = 2
qdisc = mq + fq
```

当前判断：

- 不建议使用 Joey BBR3 7.1.2 内核。
- 普通 BBR 在这台机器上更稳、更快。
- 按最新基线测试，用户要求切到普通 BBR + root FQ，不走 `mq + fq`。
- root FQ 通过 `codex-root-fq.service` 持久化，重启后自动执行：

```text
tc qdisc replace dev eth0 root fq limit 2500 flow_limit 100
```

历史上验证不适合的方向：

```text
BBR3 内核
64MB 大窗口吞吐参数
root fq limit 20000 flow_limit 1000
```

最新已改为用户指定方向：

```text
qdisc fq root limit 2500p flow_limit 100p
```

## gc-sp / 45.89.219.36 新加坡经验

gc-sp 是 45.89.219.36，新加坡方向。武汉到 VPS 的实际体验表现为：YouTube 已经很好，Speedtest 与原始版本差异很小，用户判断 Speedtest 可能更接近线路或测试点限速。调优重点应放在起速、YouTube connecting 和稳定性，不要为了 Speedtest 盲目套大窗口。

gs-cp最佳配置：

```text
kernel = 7.1.1-joeyblog-bbrv3
tcp_bbr version = 3
tcp_congestion_control = bbr
default_qdisc = fq
eth0 qdisc = root fq limit 10000 flow_limit 100
tcp_slow_start_after_idle = 0
tcp_mtu_probing = 0
tcp_notsent_lowat = 4294967295
rmem_max/wmem_max = 8388608
tcp_rmem = 4096 131072 8388608
tcp_wmem = 4096 16384 8388608
netdev_max_backlog = 2048
```

用户反馈：

- 比原始小 buffer 版本更好，YouTube 更好。
- 起速更快。
- Speedtest 与原始版本差异很小，疑似线路或测试点限速。

验证不佳档：

```text
tcp_mtu_probing = 1
tcp_notsent_lowat = 65536
rmem_max/wmem_max = 16777216
tcp_rmem = 4096 87380 16777216
tcp_wmem = 4096 65536 16777216
netdev_max_backlog = 4096
```

结果：

- 不如上一版。
- 对 45 新加坡这台来说，16MB + notsent 65536 + MTU probing 的组合偏激进。

当前判断：

- 保留 BBR3，不先动内核。
- 保留 `root fq limit 10000 flow_limit 100`。
- gc-sp 更适合“上一版节奏 + 小幅增大 buffer”，不适合直接套东京 16MB 混合档或洛杉矶 64MB 大窗口档。
- 后续若要继续试探，优先只小幅调整一个变量，例如 `rmem/wmem` 或 `fq limit`，不要同时改 MTU probing、notsent 和大窗口。

## 149.104.3.180 香港经验

149 是香港方向，低 RTT 场景，当前先按普通 Debian BBR + 温和 root FQ 档处理，不动内核，不上 BBR3。

2026-07-05 已应用并固化：

```text
kernel = 6.1.0-41-amd64
tcp_congestion_control = bbr
default_qdisc = fq
eth0 qdisc = root fq limit 2500 flow_limit 100
tcp_slow_start_after_idle = 0
tcp_mtu_probing = 1
tcp_notsent_lowat = 65536
rmem_max/wmem_max = 16777216
tcp_rmem = 4096 87380 16777216
tcp_wmem = 4096 65536 16777216
netdev_max_backlog = 4096
somaxconn = 8192
tcp_max_syn_backlog = 8192
tcp_syncookies = 1
```

持久化：

```text
/etc/sysctl.d/98-bbr-hk-balanced.conf
/etc/systemd/system/codex-root-fq.service
tc qdisc replace dev eth0 root fq limit 2500 flow_limit 100
```

本次远端备份：

```text
/root/codex-backups/sysctl.conf.bak.20260705-130220
```

## FQ 参数经验

默认 `net.core.default_qdisc = fq` 不等于一定要手动改 `tc qdisc`。

对 virtio 多队列网卡：

```text
mq + fq
```

通常比强制：

```text
root fq
```

更适合。

dmitTOKYO 已按用户 2026-07-05 的基线测试要求重新强制 root fq。

## Reality 节点检查清单

检查服务：

```text
systemctl is-active x-ui
ss -ltnp | grep -E ':(443|20223|22282)\b'
```

检查配置：

```text
/usr/local/x-ui/bin/config.json
/etc/x-ui/x-ui.db
```

重点字段：

```text
protocol = vless
network = tcp
security = reality
flow = xtls-rprx-vision
target
serverNames
privateKey
publicKey
shortIds
uuid
```

如果 `config.json` 和数据库不一致，以数据库为准，因为 x-ui 会重新生成配置。

## VLESS 链接注意事项

Reality 链接需要包含：

```text
encryption=none
type=tcp
security=reality
pbk=公钥
fp=chrome
sni=serverNames 中的域名
sid=shortId
flow=xtls-rprx-vision
```

缺少 `encryption=none` 时，有些客户端导入后会不能连接。

## SSH 和防护经验

SSH 配置：

```text
Port 22282
PasswordAuthentication no
PermitRootLogin without-password
MaxAuthTries 3
MaxSessions 10
MaxStartups 30:30:100
ClientAliveInterval 300
ClientAliveCountMax 2
```

防火墙基础放行：

```text
22282
80
443
20223
```

nftables 配置应包含：

```text
flush ruleset
```

否则重启 nftables 服务时可能重复叠加规则。

不要对 SSH 新连接做过严的 `limit rate`，否则测速/维护时短时间多次连接会出现：

```text
kex_exchange_identification: Connection closed by remote host
```

## 调参顺序建议

1. 确认节点配置能连。
2. 确认 target/SNI TLS 能握手。
3. 确认防火墙和端口监听。
4. 确认当前内核、BBR、qdisc。
5. 只改 sysctl，不先动内核。
6. 用户实测速度和断流。
7. 如果普通 BBR 已经很好，不要强上 BBR3。
8. 如果是高 RTT 跨洋链路，再考虑 BBR3 + 大窗口。

## 当前结论

154 LAX：

```text
保留 BBR3 + fq + 64MB v2 参数
```

dmitTOKYO / 191 东京品川：

```text
保留 Debian 6.1 普通 BBR + root FQ
强制 eth0 root fq limit 2500 flow_limit 100
东京低 RTT 当前最优配置：16MB buffer，tcp_notsent_lowat = 65536
BBR3 复测不理想，已回退；XanMod 内核仅保留备用，不默认启动
```

149 香港：

```text
保留 Debian 6.1 普通 BBR + root FQ
强制 eth0 root fq limit 2500 flow_limit 100
香港低 RTT 当前观察档：16MB buffer，tcp_notsent_lowat = 65536
不要启用 BBR3
```

RFC-micro / 82.40.35.69 日本：

```text
SSH 端口：22
2026-07-05 用户实测 Joey BBR3 档很拉垮，已切回官方 Debian 6.1 普通 BBR 内核
当前内核：6.1.0-44-amd64，Debian 6.1.164-1
tcp_bbr：官方 TCP BBR，不是 Joey BBR3
强制 eth0 root fq limit 2500 flow_limit 100
16MB buffer，tcp_notsent_lowat = 65536，netdev_max_backlog = 4096
持久化文件：
/etc/sysctl.d/zz-codex-bbr-fq-tuning.conf
/etc/systemd/system/codex-root-fq.service
注意：机器原有 /etc/sysctl.conf、99-sysctl.conf 有超大窗口参数覆盖，因此 codex-root-fq.service 会在 systemd-sysctl 后显式执行 sysctl -p 再套 root fq。
```

RFC-mini / 161.129.35.194 日本：

```text
SSH 端口：22
2026-07-05 参考 RFC-micro 反馈，同样从 7.1.1-joeyblog-bbrv3 切回官方 Debian 6.1 普通 BBR 内核
当前内核：6.1.0-44-amd64，Debian 6.1.164-1
tcp_bbr：官方 TCP BBR，不是 Joey BBR3
强制 eth0 root fq limit 2500 flow_limit 100
16MB buffer，tcp_notsent_lowat = 65536，netdev_max_backlog = 4096
持久化文件：
/etc/sysctl.d/zz-codex-bbr-fq-tuning.conf
/etc/systemd/system/codex-root-fq.service
```

108.171.195.152 / LAX：

```text
SSH 端口：22282
登录方式保持原样：PermitRootLogin yes，PasswordAuthentication yes
防火墙：nftables enabled / active
开放 TCP 端口：80、443、50819、22282、20223

2026-07-05 已安装并重启到 XanMod BBR3：
kernel = 6.18.37-x64v3-xanmod1
tcp_bbr = builtin，modinfo tcp_bbr 显示 version: 3
tcp_congestion_control = bbr
default_qdisc = fq
eth0 qdisc = root fq limit 8000 flow_limit 64
tcp_slow_start_after_idle = 0
tcp_mtu_probing = 0
tcp_notsent_lowat = 4294967295
rmem_max/wmem_max = 4194304
tcp_rmem = 4096 131072 4194304
tcp_wmem = 4096 16384 4194304
netdev_max_backlog = 1024

持久化文件：
/etc/sysctl.d/98-bbr3-balanced.conf
/etc/systemd/system/codex-root-fq.service

注意：XanMod 仓库包仍会写入旧源 `deb http://deb.xanmod.org releases main`，
Debian 12 当前需改为 `deb http://deb.xanmod.org bookworm main`。
本机安装的是明确版本包：
linux-image-6.18.37-x64v3-xanmod1
linux-headers-6.18.37-x64v3-xanmod1
```

相邻档位：

```text
上一档，偏吞吐：
eth0 root fq limit 10000 flow_limit 100
tcp_notsent_lowat = 131072
rmem/wmem max = 33554432
netdev_max_backlog = 8192

YouTube 优先档：
eth0 root fq limit 5000 flow_limit 100
tcp_notsent_lowat = 65536
rmem/wmem max = 16777216
netdev_max_backlog = 4096

当前固定混合档：
eth0 root fq limit 2500 flow_limit 100
tcp_notsent_lowat = 65536
rmem/wmem max = 16777216
netdev_max_backlog = 4096

更温和历史档：
eth0 root fq limit 2500 flow_limit 64
tcp_notsent_lowat = 32768
rmem/wmem max = 8388608
netdev_max_backlog = 2048
```
