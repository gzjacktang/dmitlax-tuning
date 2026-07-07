# dmitlax VPS tuning

这个仓库保存  `dmitlax` 的网络参数调优记录和一键脚本。

脚本是给你 **SSH 登录 VPS 后在 VPS 本机执行** 的，不需要在本地电脑再 SSH 到 VPS。

## 一键运行

SSH 登录 VPS 后执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/gzjacktang/dmitlax-tuning/main/dmitlax-tune-interactive.sh)
```

脚本启动后会：

- 检测当前内核、BBR 状态、`tcp_bbr version`
- 检测当前 TCP 参数和 `eth0 qdisc`
- 如果不是 BBR3，会询问是否安装 XanMod BBR3 内核
- 选择安装 BBR3 时，会先备份当前配置
- 检测 BBR3 后，询问是否加载预配置并固化
- 选择“是”会直接加载 MD 中新加坡机器最优配置；选择“否”会进入单项 TCP/FQ 调优
- 单项调优时，每个参数直接回车会使用默认值，默认值采用 MD 中新加坡机器最优配置
- 确认后写入并固化 TCP/FQ 参数
- 打印最终生效状态

预配置就是 `VPS线路优化记录.md` 里新加坡机器的最佳配置：

```text
8MB + fq 10000/100 + backlog 2048
mtu_probing = 0
tcp_notsent_lowat = 4294967295
```

BBR3 安装使用 XanMod 官方 APT 仓库方式。XanMod 官方文档说明其内核包含 BBRv3，并给出的安装步骤是注册 PGP key、添加 `deb.xanmod.org` 仓库，然后安装 `linux-xanmod-x64v3`。安装内核后需要重启 VPS 才会切到新内核。

## 下载后修改再运行

如果你想先改参数，再执行：

```bash
curl -fsSLO https://raw.githubusercontent.com/gzjacktang/dmitlax-tuning/main/dmitlax-tune-interactive.sh
nano dmitlax-tune-interactive.sh
bash dmitlax-tune-interactive.sh
```

## 参数说明

重点参数都在脚本顶部。

| 参数 | 当前默认值 | 作用 | 调整方向 |
| --- | ---: | --- | --- |
| `NETDEV` | `eth0` | 要应用 FQ 的网卡名。 | 如果 VPS 网卡不是 `eth0`，用 `ip link` 查看后修改。 |
| `RMEM_MAX` | `8388608` | TCP 接收缓冲最大值，单位字节；`8388608 = 8MB`。 | 加大可能改善长 RTT 下载/视频吞吐，过大可能增加延迟或让 Speedtest 变差。 |
| `WMEM_MAX` | `8388608` | TCP 发送缓冲最大值，单位字节；通常和 `RMEM_MAX` 同档。 | 加大可能改善上传/出站吞吐，过大也可能堆积。 |
| `TCP_RMEM_MAX` | `$RMEM_MAX` | `tcp_rmem` 第三个值，TCP 自动接收窗口上限。 | 通常跟 `RMEM_MAX` 保持一致。 |
| `TCP_WMEM_MAX` | `$WMEM_MAX` | `tcp_wmem` 第三个值，TCP 自动发送窗口上限。 | 通常跟 `WMEM_MAX` 保持一致。 |
| `NETDEV_MAX_BACKLOG` | `2048` | 网卡收包 backlog，单位是包数量，不是字节。 | 加大能吃突发，过大可能增加排队延迟。 |
| `FQ_LIMIT` | `10000` | `fq` 总队列包数上限，单位是包数量。 | `10000` 上传较稳但 YouTube 略差；`20000` 下载/YouTube 可能好但上传容易差；`15000` 是中间档。 |
| `FQ_FLOW_LIMIT` | `100` | `fq` 单 flow 包数上限，单位是包数量。 | `64` 更温和；`100` 当前较均衡；`1000` 很激进，体感可能好但 Speedtest 容易差。 |
| `TCP_MTU_PROBING` | `0` | TCP MTU 探测。 | `0` 当前更稳；遇到疑似 MTU 黑洞时可试 `1`。 |
| `TCP_NOTSENT_LOWAT` | `4294967295` | 未发送数据低水位，影响应用写入后内核积压控制。 | 当前相当于较放开；改小可控延迟，但可能影响起速/吞吐。 |
| `TCP_SLOW_START_AFTER_IDLE` | `0` | 连接空闲后是否重新慢启动。 | `0` 对视频和长连接通常更顺。 |
| `DEFAULT_QDISC` | `fq` | 默认队列算法。 | BBR 通常配 `fq`。 |
| `TCP_CONGESTION_CONTROL` | `bbr` | TCP 拥塞控制算法。 | BBR3 内核下仍然设置为 `bbr`，区别看 `tcp_bbr version`。 |
| `XANMOD_PACKAGE` | `linux-xanmod-x64v3` | 可选安装的 BBR3 内核包。 | 如果 CPU 不支持 x64v3，可改成 `linux-xanmod-x64v2` 或 `linux-xanmod-lts-x64v2`。 |

常用窗口换算：

```text
2097152  = 2MB
4194304  = 4MB
8388608  = 8MB
16777216 = 16MB
33554432 = 32MB
67108864 = 64MB
```

## 当前观察档

当前脚本默认：

```text
8MB + fq 10000/100 + backlog 2048
```

历史结论见：

```text
VPS线路优化记录.md
```

## 备份位置

每次安装 BBR3 或应用参数前，脚本都会备份到：

```text
/root/dmitlax-tune-backups/YYYYMMDD-HHMMSS/
```

里面会保存：

- 当前内核信息
- 当前 sysctl 全量输出
- 当前 qdisc
- 当前 linux 包列表
- 旧的 `/etc/sysctl.d/98-bbr3-balanced.conf`
- 旧的 `/etc/systemd/system/codex-root-fq.service`
- 旧的 XanMod APT 源配置
