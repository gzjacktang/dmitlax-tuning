# dmitlax VPS tuning

这个仓库保存 `154.21.82.9`，也就是 `dmitlax` 的网络参数调优记录和一键应用脚本。

## 一键应用

先确认本地有私钥：

```bash
.keys_lax/key-nav9zdce.pem
```

然后执行：

```bash
./scripts/apply-dmitlax-tuning.sh
```

脚本会：

- 使用 SSH 长连接复用连接 VPS
- 备份 VPS 上旧的 `/etc/sysctl.d/98-bbr3-balanced.conf`
- 备份 VPS 上旧的 `/etc/systemd/system/codex-root-fq.service`
- 写入新的 TCP/BBR 参数
- 写入并启动 root fq 持久化服务
- 打印当前生效参数

## 修改参数

直接编辑：

```bash
scripts/apply-dmitlax-tuning.sh
```

重点参数在脚本顶部：

| 参数 | 当前默认值 | 作用 | 调整方向 |
| --- | ---: | --- | --- |
| `RMEM_MAX` | `8388608` | TCP 接收缓冲最大值，单位字节；`8388608 = 8MB`。 | 加大可能改善长 RTT 下载/视频吞吐，过大可能增加延迟或让 Speedtest 变差。 |
| `WMEM_MAX` | `8388608` | TCP 发送缓冲最大值，单位字节；通常和 `RMEM_MAX` 同档。 | 加大可能改善上传/出站吞吐，过大也可能堆积。 |
| `TCP_RMEM_MAX` | `$RMEM_MAX` | `tcp_rmem` 第三个值，TCP 自动接收窗口上限。 | 通常跟 `RMEM_MAX` 保持一致。 |
| `TCP_WMEM_MAX` | `$WMEM_MAX` | `tcp_wmem` 第三个值，TCP 自动发送窗口上限。 | 通常跟 `WMEM_MAX` 保持一致。 |
| `NETDEV_MAX_BACKLOG` | `4096` | 网卡收包 backlog，单位是包数量，不是字节。 | 加大能吃突发，过大可能增加排队延迟。 |
| `FQ_LIMIT` | `15000` | `fq` 总队列包数上限，单位是包数量。 | `10000` 上传较稳但 YouTube 略差；`20000` 下载/YouTube 可能好但上传容易差；`15000` 是中间档。 |
| `FQ_FLOW_LIMIT` | `100` | `fq` 单 flow 包数上限，单位是包数量。 | `64` 更温和；`100` 当前较均衡；`1000` 很激进，体感可能好但 Speedtest 容易差。 |
| `TCP_MTU_PROBING` | `0` | TCP MTU 探测。 | `0` 当前更稳；遇到疑似 MTU 黑洞时可试 `1`。 |
| `TCP_NOTSENT_LOWAT` | `4294967295` | 未发送数据低水位，影响应用写入后内核积压控制。 | 当前相当于较放开；改小可控延迟，但可能影响起速/吞吐。 |
| `TCP_SLOW_START_AFTER_IDLE` | `0` | 连接空闲后是否重新慢启动。 | `0` 对视频和长连接通常更顺。 |
| `DEFAULT_QDISC` | `fq` | 默认队列算法。 | BBR 通常配 `fq`。 |
| `TCP_CONGESTION_CONTROL` | `bbr` | TCP 拥塞控制算法。 | 当前 dmitlax 是 BBR3 内核下的 `bbr`。 |

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
8MB + fq 15000/100 + backlog 4096
```

历史结论见：

```text
VPS线路优化记录.md
```

## GitHub 发布

本地密钥和压缩包已被 `.gitignore` 排除，不会提交到 GitHub。

如果本机已经有 GitHub CLI，可以创建远端仓库并推送：

```bash
gh repo create dmitlax-tuning --private --source=. --remote=origin --push
```

或者先在 GitHub 网页创建一个空仓库，然后执行：

```bash
git remote add origin git@github.com:你的用户名/dmitlax-tuning.git
git push -u origin main
```
