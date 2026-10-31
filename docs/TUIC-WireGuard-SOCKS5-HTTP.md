# TUIC、WireGuard、SOCKS5 与 HTTP 节点

最后核对：2026-10-25。当前工作区在原有六种协议之外，新增这四种远程节点协议；HTTP 与 HTTPS CONNECT 共用 `http` 协议类型，以 TLS 设置区分。全表见 [已支持协议与维护指南](已支持协议与维护指南.md)。

## 导入入口

在订阅页面选择“节点分享链接”粘贴链接，或导入含这些节点的文本、Base64 分享链接订阅、`proxies:` YAML。WireGuard 还支持直接粘贴单 Peer 的标准客户端配置。

“订阅 URL”入口继续下载远程订阅，不会因为地址以 HTTP/HTTPS 开头就自动改成代理节点。HTTP 代理分享链接应显式提供端口，且不能携带网站或订阅路径；普通网站链接不会直接作为代理分享链接提取。

示例均为占位配置，需要替换为自己的端点与凭证。用户名、密码、密钥或查询参数中的特殊字符应使用 URL 编码；IPv6 服务器使用方括号。

## TUIC v5

使用已有 sing-box 1.14.2 协议桥接，支持 UUID/密码、TLS、TCP 与 UDP 转发。当前不支持 TUIC v4 的 token 认证。

```text
tuic://11111111-1111-4111-8111-111111111111:password@tuic.example.com:443?alpn=h3&sni=tuic.example.com&congestion_control=bbr
```

端口默认 443，ALPN 默认 `h3`。支持以下查询参数；字段名中的下划线会按对应连字符形式识别。

| 参数 | 含义 |
| --- | --- |
| `sni`、`alpn` | TLS 服务名及逗号分隔的 ALPN |
| `congestion-control` | `cubic`、`new_reno`、`bbr` |
| `udp-relay-mode` | `native`、`quic` |
| `udp-over-stream` | sing-box 扩展 UDP 转发；不能同时指定 `udp-relay-mode` |
| `zero-rtt-handshake` | 显式启用/关闭 0-RTT；默认不启用 |
| `heartbeat` | 带单位的时长，例如 `10s`、`10000ms` |
| `certificate` | URL 编码的 PEM 信任证书，可用于私有 CA |
| `public-key-sha256` | Base64 SHA-256 **证书公钥**摘要，多个值用逗号分隔；不同于其他协议的叶证书 `pinSHA256` |
| `insecure` | 默认验证证书；只有显式传入 `true`/`1` 时才跳过验证 |
| `disable-sni` | 是否不发送 SNI，仍按所配置的 TLS 参数处理证书验证 |

YAML 使用 `type: tuic`、`uuid`、`password`、`sni`、`alpn` 等字段；接受 `congestion-controller`、`reduce-rtt` 别名。`heartbeat-interval` 按毫秒整数转换，`heartbeat` 则使用带单位的时长字符串。`skip-cert-verify` 对应显式的 `insecure`。

## WireGuard

使用 Xray 用户态 WireGuard 出站，强制 `noKernelTun=true`，协议自身不会为这个节点创建系统 TUN 或改写系统路由。若用户另行选择 HopWorld 的全量/分应用 TUN 接管，仍按既有接管流程执行。

支持一个远程 Peer、客户端私钥、Peer 公钥、可选预共享密钥、本地 IPv4/IPv6 地址、AllowedIPs、Reserved 三字节、MTU、Keepalive 和隧道内 DNS。

### 标准配置

```ini
[Interface]
PrivateKey = CLIENT_PRIVATE_KEY_BASE64
Address = 10.0.0.2/32
DNS = 1.1.1.1
MTU = 1420

[Peer]
PublicKey = SERVER_PUBLIC_KEY_BASE64
PresharedKey = OPTIONAL_PRESHARED_KEY_BASE64
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = wg.example.com:51820
PersistentKeepalive = 25
```

没有预共享密钥时移除 `PresharedKey` 行。密钥接受 32 字节 Base64 或 64 位十六进制。本地地址需明确提供，支持逗号分隔及 CIDR；`AllowedIPs` 省略时沿用核心默认全地址段。DNS 仅接受 IP 地址，配置到隧道内解析，不作为系统 DNS 设置执行。

只支持一个 `[Peer]`。未知或重复字段、多 Peer、`PostUp`/`PostDown` 等钩子、`ListenPort`、`Table` 等未接入字段会明确拒绝；**不会执行配置中的 shell 命令**。

### 分享链接和 YAML

HopWorld 的链接格式：

```text
wireguard://CLIENT_PRIVATE_KEY@wg.example.com:51820?public-key=SERVER_PUBLIC_KEY&addresses=10.0.0.2%2F32&allowed-ips=0.0.0.0%2F0%2C%3A%3A%2F0
```

也接受 `wg://`。私钥放在 URI 用户信息位置，不使用密码字段。参数包括 `public-key`（别名 `publickey`）、`addresses`（别名 `address`/`ip`）、`pre-shared-key`、`allowed-ips`、`reserved`、`mtu`、`keepalive`、`remote-dns`；端口默认 51820。

标准配置在分享链接订阅中会转换成规范 URI 保存，以便追加、更新和导出。链接格式是客户端导入约定，不保证与所有其他 WireGuard 客户端一致。

YAML 使用 `type: wireguard`、`private-key`、`public-key`、`pre-shared-key`、`ip`、`ipv6` 或 `addresses`、`allowed-ips`、`reserved`、`mtu`、`persistent-keepalive`、`remote-dns`/`dns`。当前不支持 YAML 多 Peer。

## SOCKS5

使用 Xray `socks` 出站，支持匿名、用户名密码认证、TCP 和标准 UDP relay。远端服务器也需要允许 UDP relay，TCP 测试成功不等于已验证远端 UDP。

```text
socks5://proxy.example.com:1080#Anonymous
socks5://username:password@proxy.example.com:1080#Authenticated
```

接受 `socks://` 别名，端口默认 1080。用户名/密码使用 URI 原始字段的 URL 编码形式，不支持其他客户端的任意 Base64 用户信息扩展。认证字段按 SOCKS5 字节长度校验。

当前仅接入原生 SOCKS5，没有接入 SOCKS4/4a 或额外 TLS/WS 包装。YAML 使用 `type: socks5`、`server`、`port` 和可选的 `username`/`password`。

## HTTP / HTTPS CONNECT

使用 Xray `http` 出站，支持匿名、Basic 认证和附加 CONNECT 请求头，当前使用 HTTP/1.1 CONNECT，**仅代理 TCP**。

```text
http://proxy.example.com:8080#HTTP
http://username:password@proxy.example.com:8080#Authenticated
https://username:password@proxy.example.com:443?sni=proxy.example.com#HTTPS
```

HTTP 默认端口 80，HTTPS 默认端口 443。HTTPS 必须验证证书，可使用 `sni` 与 `pinSHA256`（64 位十六进制叶证书摘要）；不接受 `insecure=1`。明文 HTTP 与原生 SOCKS5 不加密代理端点之间的传输，HTTPS CONNECT 才为该链路启用 TLS。

`headers` 接受 URL 编码的字符串键值 JSON 对象。使用 Basic 用户名时，不允许额外设置 `Proxy-Authorization`。Host、Content-Length、Transfer-Encoding、Connection、Proxy-Connection 等会干扰代理请求构造的请求头会拒绝。

YAML 使用 `type: http`；`tls: true` 表示 HTTPS CONNECT，并支持 `username`、`password`、`sni`/`servername`、`headers`、`pin-sha256`。HTTP/2/3 CONNECT、SOCKS TLS 包装和 HTTP UDP 扩展不在本次范围。

## 测试、凭证与维护

- TUIC、WireGuard 通过 UDP 建立协议链路，跳过 TCP 端口预检；SOCKS5、HTTP/HTTPS 保留 TCP 预检。
- 四种新增协议在没有代理内核时均提示无法完成实际测试，不把服务器 TCP 端口连通单独标记为代理可用。
- 保留用户配置的 **2 秒批量 HTTPS 预算**，不自动延长或重试。内核启动仍有独立的准备开销。
- 参数进入节点模型、订阅合并、配置指纹与加密保存。认证方式改变或移除认证时，不补回旧密码、私钥或认证引用。
- WireGuard 私钥/预共享密钥、HTTP 认证头及新增 URI 纳入凭证处理和日志脱敏。“不包含凭证”的备份移除节点凭证及原始分享链接文本，防止从文本恢复密钥；仍保留连接所需的非秘密参数。
- 不接受的新协议关键选项会明确报错，不把上游内核的全部能力视作客户端已接入。
- YAML 的 `udp` 仅接受与当前原生能力一致的值：TUIC/WireGuard/SOCKS5 为 `true`，HTTP 为 `false`；逐节点关闭原生 UDP 的开关尚未接入，其他取值会拒绝。

实现入口：[RemoteProtocolParser.swift](../HopWorld/Parsers/RemoteProtocolParser.swift)、[XrayConfigBuilder.swift](../HopWorld/Services/Xray/XrayConfigBuilder.swift)、[RemoteProtocolTests.swift](../HopWorldTests/RemoteProtocolTests.swift)。

本地真实内核检查使用 Xray 26.10.21 与 sing-box 1.14.2：覆盖 SOCKS5/HTTP 匿名及认证、HTTPS CONNECT、TUIC、WireGuard 的实际转发；SOCKS5/TUIC/WireGuard 的 UDP 往返；错误认证与错误信任配置拒绝。公网节点、长期稳定性及真实 TUN 接管需另行验收。

本轮新增协议 13 项检查全部通过；扩大回归共 76 项，74 项通过。另两项为协议总表中已记录的既有 `LibrarySafetyTests` 密钥注入路径失败，不能把整套回归报告为全通过。本轮没有修改 `SecureLibraryStore` 的读取/恢复逻辑。实际运行的 App 尚需使用本轮构建，历史构建不会自动获得新协议支持。

上游依据：[TUIC](https://sing-box.sagernet.org/configuration/outbound/tuic/)、[WireGuard](https://xtls.github.io/config/outbounds/wireguard.html)、[SOCKS](https://xtls.github.io/config/outbounds/socks.html)、[HTTP CONNECT](https://xtls.github.io/config/outbounds/http.html)。
