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

### byedpi

- **类型：** `byedpi`
- **`manual` 模式：** 接受 `args` 字符串
- **`auto` 模式：** 循环尝试 ByeByeDPI 策略，缓存有效的策略
- 支持 `{sni}` 替换
- UDP 默认启用并传递给 Mihomo 本地节点；`udp: false` 可将其关闭，
  ByeDPI 进程不会收到单独的 UDP 参数

## 限制

- 内置节点只能在 `proxies` 部分工作
- 本地地址和端口由客户端确定
- `auto` 模式下的 ByeDPI 仅测试 `test.urls` 中的 URL
