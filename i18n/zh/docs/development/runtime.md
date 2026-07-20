# 运行时

## 处理流程

```
RawProfile → ProfileCompiler → SecurityPolicy → RuntimePlan
```

之后，生命周期由 `EngineManager` 和 `EngineAdapter` 管理。

## 内置节点

内置节点在配置文件中定义为普通代理。它们的生命周期由 `BuiltInProxySupervisor` 管理。

### naiveproxy

- **类型：** `naiveproxy`
- **必填字段：** `name`, `proxy`
- 不支持 UDP；生成的 Mihomo 本地节点使用 `udp: false`
- 客户端自动选择本地 SOCKS5 地址
- 使用自动生成的 `config.json` 启动

### olcrtc

- **类型：** `olcrtc`
- **必填字段：** `name`, `auth.provider`, `room.id`, `crypto.key`
- 仅在 CNC（客户端）模式下工作
- 不支持 UDP；生成的 Mihomo 本地节点使用 `udp: false`

使用 `activation.mode: auto` 时，supervisor 会预先放置 OlcRTC 配置文件，但不会把休眠备用节点写入 live 或 cold-start manifest。因此，OlcRTC 的强制端到端检查不再阻塞 VPN 启动。watchdog 探测监视组，在达到失败次数后唤醒备用节点，原子地重新应用完整 plan，并强制测试 OlcRTC 本身的 delay。当空闲期内没有连接链包含该节点，且所有直接包含它的组都未选择它时，plan 会在移除该节点后再次应用。切换配置或停止时通过 generation token 取消转换；休眠状态不会持久化。

Mihomo 和网络状态通过 `RuntimeHealthProbe` 跨越 app 边界；该接口只暴露 delay 测试、活动连接链、组的 `now` 值和设备网络可用性。app layer 的实现基于 `clashCore` 与 `connectivity_plus`。未注入 probe 时，自动 watchdog 保持空闲，但 staging、停止和手动唤醒仍然安全。`always` 模式保持原来的启动事务不变。

该集成随应用的 Dart 层更新，不改变 Android bridge。运行时回退可设置 `activation: always`，回退应用版本无需迁移状态。

### byedpi

- **类型：** `byedpi`
- **`manual` 模式：** 接受 `args` 字符串
- **`auto` 模式：** 循环尝试 ByeByeDPI 策略，缓存有效的策略
- 未指定 `mode` 时，存在 `args` 表示手动模式，否则使用自动模式
- 支持 `{sni}` 替换
- UDP 默认启用并传递给 Mihomo 本地节点；`udp: false` 可将其关闭，
  ByeDPI 进程不会收到单独的 UDP 参数

## 限制

- 内置节点只能在 `proxies` 部分工作
- 本地地址和端口由客户端确定
- `auto` 模式下的 ByeDPI 使用 `strategy-test.urls` 或内置 YouTube 端点
