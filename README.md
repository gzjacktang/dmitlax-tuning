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

- `RMEM_MAX` / `WMEM_MAX`：TCP 窗口最大值，单位字节
- `TCP_RMEM_MAX` / `TCP_WMEM_MAX`：通常跟上面两个值保持一致
- `NETDEV_MAX_BACKLOG`：网卡 backlog，单位是包数量
- `FQ_LIMIT`：fq 总队列包数
- `FQ_FLOW_LIMIT`：fq 单 flow 包数
- `TCP_MTU_PROBING`：MTU 探测
- `TCP_NOTSENT_LOWAT`：未发送数据低水位

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
