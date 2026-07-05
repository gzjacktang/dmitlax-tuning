# VPS 操作约定

- 对 VPS 做测速、连续探测或批量检查时，优先建立 SSH 长连接复用（ControlMaster/ControlPath），不要短时间反复新建 SSH 连接；否则可能触发服务端/链路的新建连接限制，造成偶发 `Connection closed`，干扰测速和稳定性判断。
