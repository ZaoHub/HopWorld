# MASQUE 隧道

全项目协议能力及维护入口见 [已支持协议与维护指南](已支持协议与维护指南.md)。

HopWorld 支持标准 MASQUE CONNECT-IP（RFC 9484），由 Xray 承载节点的 TCP/UDP 流量。要求 Xray **26.10.21 或更新版本**；旧内核会提示升级，可在应用设置中更新。此次范围为标准服务端，不包含 Cloudflare WARP 设备注册及专用密钥配置。

## 导入

在订阅页面粘贴 HopWorld 的 `masque://` 分享链接，可单独导入、作为文本订阅导入，或放入 Base64 订阅。该链接格式是 HopWorld 的导入约定，不表示其他客户端均采用同一格式。

```text
masque://alice:password@masque.example.com:443?alpn=h3&sni=masque.example.com#MASQUE-H3
masque://alice:password@masque.example.com:443?alpn=h2&sni=masque.example.com#MASQUE-H2
```

用户名与密码中的特殊字符需要 URL 编码。IPv6 地址需要方括号，例如 `[2001:db8::1]:443`。未提供端口时默认为 443。

| 参数 | 作用 |
| --- | --- |
| URI 用户名、密码 | HTTP Basic 认证；用户名不能包含冒号 |
| `alpn` | 默认 `h3`；`h2` 使用 HTTP/2；同时含 `h2,h3` 时使用 HTTP/3 |
| `sni` | TLS 服务名，默认使用节点地址 |
| `host` | CONNECT-IP 请求的 authority，可带端口 |
| `path` | 默认 `/.well-known/masque/ip/{target}/{ipproto}/`，需与服务端一致 |
| `headers` | URL 编码的字符串键值 JSON 对象，可提供 Bearer 等认证头 |
| `remoteDNS` | 逗号分隔的隧道内 DNS IP 地址；省略时使用 Xray 默认值 |
| `pinSHA256` | 可选的服务端证书 SHA-256 摘要，64 位十六进制 |

例如 Bearer 认证可使用 `headers=%7B%22Authorization%22%3A%22Bearer%20YOUR_TOKEN%22%7D`，此时不要再提供 Basic 用户名/密码。`headers` 不允许包含 `Host` 或 `Capsule-Protocol`；使用 `host` 参数设置 authority。

路径必须以 `/` 开头，仅支持 `{target}`、`{ipproto}` 及其查询模板组合。未知、重复或不受支持的链接参数会被拒绝，避免静默丢失连接要求。MASQUE 必须使用 TLS，不能设置 `insecure=1`；自签名服务端可使用正确的 `pinSHA256`。

也支持 `proxies:` YAML 列表中的 MASQUE 条目：

```yaml
proxies:
  - name: MASQUE-H2
    type: masque
    server: masque.example.com
    port: 443
    username: alice
    password: password
    alpn: [h2]
    sni: masque.example.com
    path: /.well-known/masque/ip/{target}/{ipproto}/
    remote-dns: [1.1.1.1, '2606:4700:4700::1111']
```

YAML 另可使用 `host`、`headers` 字符串映射与 `pin-sha256`。不支持 WARP 配置或跳过证书验证。上述 YAML 字段是 HopWorld 支持的导入形式，不保证其他 Clash 类客户端支持 `type: masque`。

## 测试和连接

导入后使用现有节点测试、应用连通测试与连接入口，沿用路由和系统接管设置。HTTP/3 经 UDP 建立隧道，跳过节点 TCP 端口预检；HTTP/2 仍执行 TCP 预检。没有代理内核时，单纯 TCP 成功不会把 MASQUE 标记为可用。

**保留用户设置的 2 秒批量 HTTPS 预算**，不隐式延长，也不自动重复测试。超时只反映该次预算内的探测结果。

新认证字段保存在现有加密节点库中，并参与订阅配置变更判断。订阅从 Basic 改为 Bearer 或移除认证时，不沿用旧认证字段。日志会脱敏 MASQUE 链接；备份选择“不包含凭证”时移除节点上的用户名、密码及请求头。分享链接包含连接凭证，应仅分享给受信任者。

## 验证与边界

自动化检查覆盖链接/IPv6/特殊字符往返、文本/Base64/YAML 导入、参数校验、旧节点数据兼容、加密备份、订阅认证变更、旧内核提示、混合批量配置及 2 秒预算。

本地隧道检查使用 Xray 26.10.21、临时自签名证书和正确的证书固定摘要，分别验证 H2/H3 的 TCP 请求及 UDP 往返。无需管理员权限，不更改系统代理或系统路由。公网服务端、长期稳定性、真实 TUN 接管仍需实际环境验收。

2026-10-25 验证：Debug 构建成功；扩大回归共 63 项，61 项通过。MASQUE 全部 7 项、2 秒预算与 H3 预检检查通过，错误密码和错误证书摘要均被拒绝。另有两项现有存储测试失败：`LibrarySafetyTests.testMigrationEncryptsAllSecretsAndRemovesLegacyOnlyAfterSuccessfulCommit` 与 `testDamagedPrimaryRestoresWholePreviousCommitAndRetainsDamagedFile`；`SecureLibraryStore.load()` 读取已有加密文件时直接调用钥匙串候选密钥，绕过测试构造器注入的密钥。本次未修改该存储恢复逻辑，不把扩大回归报告为全部通过。

依据：[Xray MASQUE 出站](https://xtls.github.io/config/outbounds/masque.html)、[MASQUE 传输](https://xtls.github.io/config/transports/masque.html)、[MASQUE 入站](https://xtls.github.io/config/inbounds/masque.html)。
