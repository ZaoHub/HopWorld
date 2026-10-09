# macOS 可视化 Xray/V2Ray 代理客户端开发文档 V1.0

> 文档目标：开发一个 macOS 原生可视化代理客户端，通过订阅或单节点链接导入代理节点，按国家/地区自动分类、测速并一键切换。  
> 应用名称：跃界（英文：HopWorld）  
> 建议首版：**系统代理模式**；第二阶段增加 **TUN 全局代理模式**。  
> 建议最低系统：macOS 14+。Apple Silicon 优先，后续可补充 x86_64。  
> 文档日期：2026-09-25。

---

## 1. 产品目标

应用面向不希望直接操作 Xray/V2Ray 配置文件的用户。

用户只需要完成：

1. 添加订阅地址或单节点链接；
2. App 自动解析节点；
3. 自动识别节点国家/地区；
4. 自动测试节点；
5. 点击“美国 / 日本 / 新加坡”等国家；
6. App 自动选择该国家最优节点；
7. 启动 Xray-core；
8. 自动启用 macOS 系统代理；
9. 显示当前出口 IP、国家、延迟和流量；
10. 订阅按设定时间自动更新。

第一版重点不是把 Xray 的所有参数暴露给普通用户，而是：

> **把复杂的 Xray 节点转换成“国家 → 节点 → 一键连接”的可视化体验。**

---

# 2. 首版功能范围

## 2.1 首页

首页建议展示：

- 当前连接状态；
- 当前国家；
- 当前节点；
- 当前协议；
- 当前延迟；
- 当前出口 IP；
- 当前出口国家；
- 当前下载速度；
- 当前上传速度；
- 本次连接累计下载；
- 本次连接累计上传；
- 一键连接 / 断开；
- 快速切换国家；
- 最近使用节点；
- 自动优选开关。

示例：

```text
┌──────────────────────────────────────────────────┐
│ ProxyHub                            ● 已连接      │
├────────────┬─────────────────────────────────────┤
│ 概览       │                                     │
│ 国家       │            🇯🇵 日本                  │
│ 节点       │         Tokyo Premium 01             │
│ 订阅       │              32 ms                   │
│ 测试       │                                     │
│ 路由       │        [       断开       ]          │
│ 设置       │                                     │
│            │  出口 IP   203.xxx.xxx.xxx          │
│            │  ↓ 21.4 Mbps   ↑ 8.3 Mbps          │
│            │                                     │
│            │  快速切换                           │
│            │  🇺🇸 美国      82 ms                │
│            │  🇯🇵 日本      32 ms   ✓            │
│            │  🇸🇬 新加坡    49 ms                │
│            │  🇭🇰 香港      41 ms                │
└────────────┴─────────────────────────────────────┘
```

---

# 3. 技术架构

```text
┌───────────────────────────────────────────┐
│                 SwiftUI UI                │
├───────────────────────────────────────────┤
│ Dashboard / Nodes / Subscription / Test   │
│ Routing / Settings / Logs                 │
├───────────────────────────────────────────┤
│              Application Layer            │
│                                           │
│ ConnectionManager                         │
│ SubscriptionManager                       │
│ SubscriptionScheduler                     │
│ NodeManager                               │
│ NodeTestManager                           │
│ CountryResolver                           │
│ RoutingManager                            │
│ ProxySystemManager                        │
│ XrayProcessManager                        │
├───────────────────────────────────────────┤
│                Data Layer                 │
│                                           │
│ SwiftData / CoreData                      │
│ Keychain                                  │
│ JSON / YAML Parser                        │
├───────────────────────────────────────────┤
│                 Xray-core                 │
│                                           │
│ SOCKS / HTTP / VLESS / VMess / Trojan    │
│ Shadowsocks / REALITY / XTLS / Routing   │
└───────────────────────────────────────────┘
```

---

# 4. 推荐项目结构

```text
ProxyHub/
├── App/
│   ├── ProxyHubApp.swift
│   ├── AppState.swift
│   └── AppEnvironment.swift
│
├── Models/
│   ├── ProxyNode.swift
│   ├── Subscription.swift
│   ├── SubscriptionUpdateRule.swift
│   ├── NodeTestResult.swift
│   ├── CountryGroup.swift
│   ├── RoutingProfile.swift
│   └── ConnectionState.swift
│
├── Views/
│   ├── Dashboard/
│   │   └── DashboardView.swift
│   ├── Nodes/
│   │   ├── NodeListView.swift
│   │   └── NodeDetailView.swift
│   ├── Countries/
│   │   └── CountryListView.swift
│   ├── Subscriptions/
│   │   ├── SubscriptionListView.swift
│   │   ├── SubscriptionEditorView.swift
│   │   └── DateTemplatePreviewView.swift
│   ├── Testing/
│   │   ├── TestCenterView.swift
│   │   └── TestDetailView.swift
│   ├── Routing/
│   │   └── RoutingView.swift
│   ├── Settings/
│   │   └── SettingsView.swift
│   └── Logs/
│       └── LogView.swift
│
├── Services/
│   ├── Xray/
│   │   ├── XrayProcessManager.swift
│   │   ├── XrayConfigBuilder.swift
│   │   ├── XrayValidator.swift
│   │   └── XrayStatsService.swift
│   │
│   ├── Subscription/
│   │   ├── SubscriptionManager.swift
│   │   ├── SubscriptionFetcher.swift
│   │   ├── SubscriptionParser.swift
│   │   ├── SubscriptionDateTemplate.swift
│   │   ├── SubscriptionScheduler.swift
│   │   └── SubscriptionMerger.swift
│   │
│   ├── Testing/
│   │   ├── NodeTestManager.swift
│   │   ├── TCPTester.swift
│   │   ├── ProxyHTTPTester.swift
│   │   ├── ThroughputTester.swift
│   │   └── ExitIPTester.swift
│   │
│   ├── System/
│   │   ├── SystemProxyManager.swift
│   │   ├── NetworkServiceDetector.swift
│   │   ├── ProxyRestoreManager.swift
│   │   └── BackgroundAgentManager.swift
│   │
│   ├── Country/
│   │   ├── CountryResolver.swift
│   │   └── FlagResolver.swift
│   │
│   └── Security/
│       └── KeychainStore.swift
│
├── Parsers/
│   ├── VLESSParser.swift
│   ├── VMessParser.swift
│   ├── TrojanParser.swift
│   ├── ShadowsocksParser.swift
│   ├── ClashYAMLParser.swift
│   └── Base64SubscriptionParser.swift
│
├── Resources/
│   ├── xray
│   ├── geoip.dat
│   ├── geosite.dat
│   └── DefaultRouting.json
│
└── Tests/
    ├── ParserTests/
    ├── DateTemplateTests/
    ├── MergeTests/
    ├── NodeTestTests/
    └── XrayConfigTests/
```

---

# 5. 节点数据模型

建议所有协议统一转换成内部 `ProxyNode`。

```swift
struct ProxyNode: Identifiable, Codable, Hashable {
    let id: UUID

    var name: String
    var protocolType: ProxyProtocol

    var server: String
    var port: Int

    // 敏感字段建议实际存 Keychain，只在运行时装载
    var credentialKey: String?

    var uuid: String?
    var password: String?
    var method: String?

    var transport: TransportType
    var security: SecurityType

    var sni: String?
    var host: String?
    var path: String?
    var serviceName: String?
    var publicKey: String?
    var shortID: String?
    var fingerprint: String?

    var countryCode: String?
    var countryName: String?
    var city: String?

    var subscriptionID: UUID?
    var sourceName: String?

    var lastLatency: Int?
    var lastTestDate: Date?
    var lastTestStatus: NodeTestStatus

    var enabled: Bool
}
```

协议枚举：

```swift
enum ProxyProtocol: String, Codable {
    case vless
    case vmess
    case trojan
    case shadowsocks
}
```

传输类型：

```swift
enum TransportType: String, Codable {
    case tcp
    case ws
    case grpc
    case httpupgrade
    case xhttp
    case quic
}
```

安全类型：

```swift
enum SecurityType: String, Codable {
    case none
    case tls
    case reality
}
```

---

# 6. 节点导入

## 6.1 支持来源

V1 建议支持：

- VLESS；
- VMess；
- Trojan；
- Shadowsocks；
- Base64 订阅；
- 普通文本订阅；
- Clash YAML；
- 剪贴板；
- 本地文件；
- 二维码；
- 手动录入。

例如：

```text
vless://...
vmess://...
trojan://...
ss://...
```

---

# 7. 订阅系统

订阅是本项目的重要模块。

一个订阅不仅包含 URL，还应该包含：

- 名称；
- 原始输入 URL；
- URL 模板；
- 当前解析后的 URL；
- 下次解析 URL；
- 是否自动更新；
- 更新时间；
- 更新时间区；
- 更新周期；
- 日期偏移；
- URL 失败回退；
- 覆盖 / 合并策略；
- 是否自动测试新节点；
- 是否自动删除失效节点；
- 最近成功时间；
- 最近失败时间；
- 最近 HTTP 状态码；
- 最近错误；
- ETag；
- Last-Modified；
- 内容 Hash。

数据结构：

```swift
struct Subscription: Identifiable, Codable {
    let id: UUID

    var name: String

    var originalURL: String
    var urlTemplate: String?
    var resolvedURL: String?

    var isEnabled: Bool
    var autoUpdate: Bool

    var updateTime: DateComponents
    var updateInterval: SubscriptionInterval
    var timeZoneID: String

    var dateOffset: Int
    var fallbackDays: Int

    var updateMode: SubscriptionUpdateMode

    var testAfterUpdate: Bool
    var removeUnavailableNodes: Bool

    var lastAttemptAt: Date?
    var lastSuccessAt: Date?
    var nextUpdateAt: Date?

    var lastHTTPStatus: Int?
    var lastError: String?

    var etag: String?
    var lastModified: String?
    var contentHash: String?
}
```

---

# 8. 日期型订阅 URL

这是本项目需要重点实现的功能。

用户给出的例子：

```text
https://node.nodefree.me/2026/08/20260818.txt
```

对应日期：

```text
2026-08-18
```

App 自动识别成：

```text
https://node.nodefree.me/{yyyy}/{MM}/{yyyyMMdd}.txt
```

另一个：

```text
https://clashgithub.com/wp-content/uploads/rss/20260818.txt
```

自动识别成：

```text
https://clashgithub.com/wp-content/uploads/rss/{yyyyMMdd}.txt
```

因此第二天无需用户修改订阅。

2026-08-19 自动变为：

```text
https://node.nodefree.me/2026/08/20260819.txt
```

和：

```text
https://clashgithub.com/wp-content/uploads/rss/20260819.txt
```

进入 2026-09-01 后第一条会自动变为：

```text
https://node.nodefree.me/2026/09/20260901.txt
```

---

# 9. 日期模板格式

建议内部支持以下占位符：

| 模板 | 含义 | 示例 |
|---|---|---|
| `{yyyy}` | 4 位年份 | 2026 |
| `{yy}` | 2 位年份 | 26 |
| `{MM}` | 2 位月份 | 08 |
| `{M}` | 月份 | 8 |
| `{dd}` | 2 位日期 | 18 |
| `{d}` | 日期 | 18 |
| `{yyyyMMdd}` | 年月日 | 20260818 |
| `{yyyy-MM-dd}` | 日期 | 2026-08-18 |
| `{yyyy_MM_dd}` | 日期 | 2026_08_18 |

允许用户手动编辑模板。

例如：

```text
https://example.com/{yyyy}/{MM}/{yyyyMMdd}.txt
```

或者：

```text
https://example.com/sub-{yyyy-MM-dd}.yaml
```

---

# 10. 自动识别日期模板

## 10.1 检测原则

添加订阅 URL 后扫描：

### 第一级

检测连续 8 位数字：

```regex
(?<!\d)(20\d{2})(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])(?!\d)
```

例如：

```text
20260818
```

识别：

```text
{yyyyMMdd}
```

### 第二级

检测：

```text
/2026/08/
```

如果该年月与 8 位日期中的年月一致，则转换：

```text
/{yyyy}/{MM}/
```

因此：

```text
https://node.nodefree.me/2026/08/20260818.txt
```

得到：

```text
https://node.nodefree.me/{yyyy}/{MM}/{yyyyMMdd}.txt
```

### 第三级

支持：

```text
2026-08-18
2026_08_18
2026/08/18
```

但是：

> **不能看到任意数字就强制判断为日期。**

自动检测完成后必须向用户展示：

```text
检测到日期型订阅

原地址：
https://node.nodefree.me/2026/08/20260818.txt

模板：
https://node.nodefree.me/{yyyy}/{MM}/{yyyyMMdd}.txt

今天：
https://node.nodefree.me/2026/09/25/20260925.txt

明天：
https://node.nodefree.me/2026/09/26/20260926.txt
```

用户可选择：

```text
○ 固定地址
● 自动日期地址
```

---

# 11. 日期模板 Swift 示例

```swift
struct SubscriptionDateTemplate {

    let template: String

    func resolve(
        date: Date,
        timeZone: TimeZone
    ) -> String {

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let components = calendar.dateComponents(
            [.year, .month, .day],
            from: date
        )

        guard
            let year = components.year,
            let month = components.month,
            let day = components.day
        else {
            return template
        }

        let yyyy = String(format: "%04d", year)
        let yy = String(format: "%02d", year % 100)
        let MM = String(format: "%02d", month)
        let M = "\(month)"
        let dd = String(format: "%02d", day)
        let d = "\(day)"
        let yyyyMMdd = "\(yyyy)\(MM)\(dd)"

        return template
            .replacingOccurrences(of: "{yyyyMMdd}", with: yyyyMMdd)
            .replacingOccurrences(of: "{yyyy-MM-dd}", with: "\(yyyy)-\(MM)-\(dd)")
            .replacingOccurrences(of: "{yyyy_MM_dd}", with: "\(yyyy)_\(MM)_\(dd)")
            .replacingOccurrences(of: "{yyyy}", with: yyyy)
            .replacingOccurrences(of: "{yy}", with: yy)
            .replacingOccurrences(of: "{MM}", with: MM)
            .replacingOccurrences(of: "{M}", with: M)
            .replacingOccurrences(of: "{dd}", with: dd)
            .replacingOccurrences(of: "{d}", with: d)
    }
}
```

---

# 12. 更新时间

每个订阅可以独立设置。

UI：

```text
自动更新                 [开启]

更新周期
[ 每天 ▼ ]

更新时间
[ 08 : 30 ]

日期时区
[ Asia/Shanghai ▼ ]

地址日期偏移
[ 当天 ▼ ]

若当天地址不可用
[ 向前查找 3 天 ▼ ]

更新完成后测试节点       [开启]

更新方式
● 覆盖
○ 合并
○ 智能合并
```

---

# 13. 更新时间区

日期型 URL **必须绑定时区**。

否则用户电脑位于美国，但订阅发布源按照中国时间生成文件时，会出现日期提前/滞后问题。

建议：

```text
默认：
Asia/Shanghai
```

但允许用户选择：

```text
系统时区
Asia/Shanghai
Asia/Tokyo
America/New_York
UTC
自定义
```

注意：

更新时间使用的时区与 URL 日期计算的时区，可以默认相同。

高级模式允许分别设置：

```text
执行时区：America/New_York
URL 日期时区：Asia/Shanghai
```

---

# 14. 日期偏移

部分订阅站点不是当天 00:00 立即发布。

因此必须支持：

```text
日期：
当天
昨天
前天
自定义 -N 天
```

内部字段：

```swift
var dateOffset: Int
```

例如：

```text
0  = 今天
-1 = 昨天
-2 = 前天
```

---

# 15. 自动回退日期

这是强烈建议加入的功能。

例如：

```text
2026-09-25 08:00
```

程序生成：

```text
https://example.com/20260925.txt
```

但是服务器今天还没更新。

HTTP 返回：

```text
404
```

此时自动尝试：

```text
20260924.txt
20260923.txt
20260922.txt
```

用户可以设置：

```text
当天不存在时：

○ 不回退
● 自动向前查找

最多查找：
[ 3 ] 天
```

流程：

```text
请求 D0
 │
 ├─ 有效 → 使用
 │
 └─ 无效
      ↓
     D-1
      │
      ├─ 有效 → 使用
      └─ 无效
           ↓
          D-2
           ...
```

但是必须在 UI 明确显示：

```text
今日订阅尚未发布
当前使用：2026-09-24
```

不能让用户误以为已经获取到 9 月 25 日数据。

---

# 16. 自动更新调度

推荐逻辑：

```text
App 启动
   ↓
计算所有 nextUpdateAt
   ↓
到达更新时间
   ↓
生成当天 URL
   ↓
下载
   ↓
验证
   ↓
解析
   ↓
去重
   ↓
覆盖/合并
   ↓
测试
   ↓
保存
```

如果电脑在设定更新时间处于睡眠或关机：

```text
App/后台服务恢复
       ↓
检查 missedUpdate
       ↓
如果今天没有成功更新
       ↓
立即补更新
```

不要简单地等到第二天。

建议记录：

```swift
lastAttemptAt
lastSuccessAt
nextUpdateAt
lastResolvedDate
lastResolvedURL
```

---

# 17. 后台更新

## 17.1 简单版

App 正在运行：

```swift
Timer
+
SubscriptionScheduler
```

满足第一版开发和调试。

## 17.2 正式版

如果希望 App 界面关闭以后仍然能够按照时间更新，建议使用 macOS 的后台辅助进程。

macOS 13+ 可以使用：

```text
ServiceManagement
SMAppService
LaunchAgent
```

结构：

```text
ProxyHub.app
        │
        ├── 主程序
        │
        └── ProxyHubAgent
                │
                ├── 定时检查订阅
                ├── 下载订阅
                └── 通知主程序
```

使用 XPC 在主程序与 Agent 之间通信。

注意：

- 后台服务必须允许用户关闭；
- UI 中显示后台服务状态；
- 不要隐藏创建后台项目；
- 后台进程不应该直接弹 UI；
- 更新结果可通过 UserNotifications 或主 App 状态显示。

---

# 18. 订阅下载验证

下载成功并不等于订阅有效。

必须经过：

```text
HTTP
 ↓
内容长度检查
 ↓
编码检测
 ↓
格式识别
 ↓
节点解析
 ↓
有效节点数量
 ↓
内容 Hash
```

## 18.1 请求条件

建议：

```text
Timeout：15 秒
Redirect：允许，限制次数
HTTP 200：继续
HTTP 304：没有变化
HTTP 4xx：失败
HTTP 5xx：失败/重试
空内容：失败
```

支持保存：

```text
ETag
Last-Modified
```

后续发送：

```text
If-None-Match
If-Modified-Since
```

避免重复下载。

---

# 19. 内容有效性

不要因为 HTTP 200 就覆盖旧节点。

必须满足：

```text
HTTP 成功
AND
内容长度 > 最小阈值
AND
解析器成功
AND
有效节点数量 >= 1
```

才允许进入更新阶段。

例如服务器返回：

```html
403 Forbidden
```

即使 HTTP 层错误处理异常，也不能把 HTML 当节点订阅覆盖本地数据。

---

# 20. 内容 Hash

每次下载后：

```text
SHA256(subscription body)
```

如果：

```text
newHash == oldHash
```

则显示：

```text
订阅没有变化
```

无需重新写数据库，也可以根据设置决定是否重新测速。

---

# 21. 覆盖 / 合并模式

## 21.1 覆盖

```text
旧订阅节点
A
B
C

新订阅节点
B
C
D

更新后：
B
C
D
```

A 被删除。

适合：

> 每日完整订阅文件。

规则：

- 只有新订阅验证成功才执行；
- 下载失败时绝对不能清空旧订阅；
- 保留收藏、备注等用户数据。

---

# 22. 合并

```text
旧：
A B C

新：
B C D

结果：
A B C D
```

适合：

> 每天地址只追加部分节点，用户希望长期积累。

需要配合自动清理功能，否则节点会越来越多。

---

# 23. 智能合并

推荐默认提供第三种：

```text
智能合并
```

流程：

```text
新节点
  ↓
计算 nodeFingerprint
  ↓
已有？
 ├─ 是 → 更新参数
 └─ 否 → 新增
```

旧节点如果本次订阅没有出现：

```text
不立刻删除
```

而是：

```text
missingCount += 1
```

例如连续 3 次更新未出现：

```text
missingCount >= 3
```

再标记：

```text
可能已移除
```

可由用户设置：

```text
连续缺失 [3] 次后自动删除
```

---

# 24. 节点唯一 Fingerprint

不能只按照节点名称去重。

例如：

```text
香港高速01
香港高速01
```

可能其实是不同服务器。

建议构造：

```text
protocol
server
port
credential
transport
security
sni
host
path
serviceName
publicKey
shortID
```

标准化后：

```text
SHA256(canonicalNodeString)
```

例如：

```swift
func nodeFingerprint(_ node: ProxyNode) -> String {
    let raw = [
        node.protocolType.rawValue.lowercased(),
        node.server.lowercased(),
        "\(node.port)",
        node.uuid ?? "",
        node.password ?? "",
        node.transport.rawValue.lowercased(),
        node.security.rawValue.lowercased(),
        node.sni?.lowercased() ?? "",
        node.host?.lowercased() ?? "",
        node.path ?? "",
        node.serviceName ?? "",
        node.publicKey ?? "",
        node.shortID ?? ""
    ].joined(separator: "|")

    return sha256(raw)
}
```

数据库只保存 Hash。

认证字段本身应存 Keychain。

---

# 25. 更新过程必须原子化

错误做法：

```text
先删除旧节点
↓
再下载
↓
下载失败
↓
节点全没了
```

正确：

```text
下载新内容
↓
解析到临时区
↓
验证
↓
生成更新计划
↓
数据库事务
↓
Commit
```

任何步骤失败：

```text
Rollback
```

旧节点继续可用。

---

# 26. 更新历史

每个订阅保存最近至少 30 条更新记录。

```swift
struct SubscriptionUpdateLog {
    var startedAt: Date
    var finishedAt: Date?

    var requestedURL: String

    var httpStatus: Int?
    var success: Bool

    var fetchedCount: Int
    var addedCount: Int
    var updatedCount: Int
    var removedCount: Int
    var duplicateCount: Int
    var invalidCount: Int

    var contentHash: String?
    var errorMessage: String?
}
```

UI：

```text
2026-09-25 08:30
成功
使用地址：
https://node.nodefree.me/2026/09/20260925.txt

获取：156
新增：18
更新：93
移除：11
重复：31
无效：3
```

---

# 27. 订阅页面 UI

```text
┌─────────────────────────────────────────────────────┐
│ 订阅                                                │
├─────────────────────────────────────────────────────┤
│ NodeFree                               ● 正常       │
│ 自动更新：每天 08:30                                │
│ 模式：智能合并                                      │
│ 最近更新：今天 08:30                                │
│ 节点：128                                           │
│                                                     │
│ 当前地址                                            │
│ node.nodefree.me/2026/09/20260925.txt               │
│                                                     │
│ 下一地址                                            │
│ node.nodefree.me/2026/09/20260926.txt               │
│                                                     │
│ [立即更新] [测试地址] [编辑]                        │
└─────────────────────────────────────────────────────┘
```

---

# 28. 订阅地址测试功能

用户点击：

```text
测试地址
```

不改变现有节点。

测试：

```text
1. URL 模板解析
2. DNS
3. HTTPS 连接
4. HTTP 状态
5. 下载大小
6. 内容格式
7. 节点数量
8. 重复节点
9. 无效节点
```

结果：

```text
订阅测试完成

解析 URL：
https://node.nodefree.me/2026/09/20260925.txt

HTTP：
200 OK

下载：
87 KB

格式：
Base64 Subscription

解析：
156 个节点

有效：
149

重复：
5

无效：
2

耗时：
842 ms
```

提供：

```text
[仅测试]
```

和：

```text
[测试并更新]
```

两种动作。

---

# 29. 节点测试中心

用户明确要求“测试功能”，建议不要只实现 Ping。

一个完整节点测试至少分 6 层。

```text
① 配置检查
② DNS
③ TCP
④ 代理握手
⑤ HTTP 可用性
⑥ 出口 IP / 国家
```

高级：

```text
⑦ 下载速度
⑧ UDP
⑨ IPv6
```

---

# 30. 测试层级 1：配置检查

检查：

```text
server 非空
port 1...65535
UUID 格式
security 参数
Reality publicKey
Reality shortId
SNI
WS path
gRPC serviceName
Shadowsocks method
```

并生成临时 Xray 配置后执行 Xray 配置验证。

任何配置错误：

```text
不进入网络测试。
```

---

# 31. 测试层级 2：DNS

如果服务器地址是域名：

```text
example.com
```

测试：

```text
DNS 解析耗时
IPv4
IPv6
```

结果：

```text
DNS：正常
12 ms
IPv4: 1.2.3.4
IPv6: 2400:...
```

---

# 32. 测试层级 3：TCP

直接测试：

```text
server:port
```

TCP connect。

例如：

```text
东京节点
TCP：31 ms
```

注意：

> TCP 连得上，不代表代理协议可用。

所以 TCP 延迟不能直接作为最终节点延迟。

---

# 33. 测试层级 4：代理握手

真正启动 Xray，让测试请求经过：

```text
本机
↓
Xray inbound
↓
目标节点
↓
Internet
```

如果：

```text
TCP server 连接正常
```

但是：

```text
UUID 错误
Reality 参数错误
TLS 错误
```

此阶段会失败。

这能过滤大量“端口在线但节点不可用”的假可用节点。

---

# 34. 测试层级 5：HTTP 可用性

建议请求一个可配置的轻量 HTTP/HTTPS 测试地址。

用户设置：

```text
连通性测试 URL：
https://example-test-endpoint/generate_204
```

要求：

```text
响应小
稳定
支持 HTTPS
不会产生大量流量
```

应用允许用户配置多个测试地址作为 fallback。

测量：

```text
Proxy RTT
```

定义：

```text
从客户端发出请求
到收到 HTTP 首字节的耗时
```

这比单纯 ping 更接近实际代理体验。

---

# 35. 测试层级 6：出口 IP

通过当前节点访问一个 IP 查询服务：

```text
客户端
↓
Xray
↓
代理节点
↓
IP API
```

解析：

```text
IP
Country
Region
City
ASN
ISP
```

结果：

```text
出口 IP：103.xxx.xxx.xxx
国家：日本
地区：Tokyo
ASN：ASxxxxx
```

该结果还可以反向纠正节点国家分类。

---

# 36. 测试层级 7：下载速度

测速属于可选项。

不要每次自动更新后对全部节点执行大流量测速。

建议：

```text
快速测试
```

只测：

```text
配置 + TCP + HTTP RTT
```

而：

```text
完整测试
```

才增加：

```text
下载速度
出口 IP
UDP
```

建议测速数据量可设置：

```text
1 MB
5 MB
10 MB
20 MB
```

默认：

```text
5 MB
```

---

# 37. 测试层级 8：UDP

可选。

用于判断：

- DNS UDP；
- 游戏；
- QUIC；
- 某些实时通信；

是否可通过当前节点。

显示：

```text
UDP
✓ 可用
```

或者：

```text
UDP
— 未测试
```

不要因为 UDP 不可用直接判定整个节点不可用。

---

# 38. 测试状态

建议：

```swift
enum NodeTestStatus {
    case untested
    case testing
    case available
    case degraded
    case unavailable
}
```

UI：

```text
● 可用
● 较慢
● 不可用
○ 未测试
```

不要仅使用颜色，必须同时带文字或图标。

---

# 39. 节点测试结果模型

```swift
struct NodeTestResult: Codable {
    var nodeID: UUID

    var startedAt: Date
    var finishedAt: Date

    var configValid: Bool

    var dnsLatency: Int?
    var tcpLatency: Int?
    var proxyLatency: Int?

    var downloadMbps: Double?

    var udpAvailable: Bool?

    var exitIP: String?
    var exitCountryCode: String?
    var exitCountryName: String?
    var asn: String?

    var success: Bool
    var failureStage: TestStage?
    var errorMessage: String?
}
```

---

# 40. 并发测试架构

不要一次启动 100 个单独 Xray 进程。

推荐测试时生成一个临时 Xray 配置：

```text
Node A → outbound-a
Node B → outbound-b
Node C → outbound-c
```

同时生成：

```text
127.0.0.1:21001 → outbound-a
127.0.0.1:21002 → outbound-b
127.0.0.1:21003 → outbound-c
```

结构：

```text
HTTP/SOCKS 21001
       ↓
 outbound-A

HTTP/SOCKS 21002
       ↓
 outbound-B

HTTP/SOCKS 21003
       ↓
 outbound-C
```

App 分别通过对应本机端口执行测试。

建议并发：

```text
默认 8
```

允许：

```text
4
8
16
32
```

不要无限并发。

---

# 41. 节点测试排序

用户可以选择：

```text
排序：
延迟最低
下载最快
最近可用
国家
名称
```

自动优选国家时建议使用：

```text
综合策略
```

但不要只使用一次测试。

简单评分可以内部使用：

```text
节点必须首先满足：
success == true
```

再按：

```text
近期代理 RTT
+
连续成功次数
+
失败次数
```

选择。

用户界面最终展示的是：

```text
推荐
```

而不是暴露复杂分数。

---

# 42. 国家识别

优先级建议：

```text
1. 实际出口 IP 国家
2. 节点服务器 IP GeoIP
3. 节点名称关键词
4. 未知
```

名称解析仅作为辅助。

例如：

```text
US
USA
United States
美国
洛杉矶
纽约
Seattle
LA
NY
```

映射：

```text
US
```

但如果实际出口测试显示：

```text
JP
```

则允许标记：

```text
名称：美国01
实际出口：日本
```

---

# 43. 国家分组

内部：

```swift
struct CountryGroup {
    var code: String
    var name: String
    var flag: String
    var nodes: [ProxyNode]
}
```

UI：

```text
🇭🇰 香港       12
🇯🇵 日本       18
🇸🇬 新加坡      9
🇺🇸 美国       22
🇩🇪 德国        4
🌐 其他         6
```

---

# 44. 一键连接国家

点击：

```text
🇯🇵 日本
```

流程：

```text
读取日本节点
↓
过滤 disabled
↓
过滤近期明确不可用
↓
取最近测试结果
↓
如结果过期则快速测试候选节点
↓
选择最快可用节点
↓
生成 Xray config
↓
启动 Xray
↓
验证本地端口
↓
开启 macOS 系统代理
↓
出口 IP 二次验证
↓
完成
```

---

# 45. 连接失败自动切换

例如日本：

```text
JP-01
JP-02
JP-03
```

连接 JP-01 失败：

```text
↓
JP-02
```

失败：

```text
↓
JP-03
```

成功：

```text
停止轮询
```

用户可以设置：

```text
自动故障切换       [开启]
最大尝试节点       [3]
```

---

# 46. Xray-core 管理

建议打包：

```text
ProxyHub.app
└── Contents
    └── Resources
        ├── xray
        ├── geoip.dat
        └── geosite.dat
```

XrayProcessManager：

```swift
actor XrayProcessManager {

    private var process: Process?

    func start(configURL: URL) throws {
        stop()

        let process = Process()

        process.executableURL = Bundle.main.url(
            forResource: "xray",
            withExtension: nil
        )

        process.arguments = [
            "run",
            "-config",
            configURL.path
        ]

        try process.run()

        self.process = process
    }

    func stop() {
        guard let process else { return }

        if process.isRunning {
            process.terminate()
        }

        self.process = nil
    }
}
```

生产版本还应补：

- stdout/stderr；
- 进程崩溃检测；
- 启动超时；
- PID；
- 优雅退出；
- 强制退出 fallback；
- 崩溃后系统代理恢复。

---

# 47. Xray 配置生成

核心原则：

```text
内部模型
↓
XrayConfigBuilder
↓
config.json
↓
验证
↓
启动
```

不要直接把订阅内容原样传给核心。

这样可以统一处理：

- 路由；
- DNS；
- 本地端口；
- 日志；
- stats；
- 测试；
- IPv6；
- bypass。

---

# 48. 本地代理端口

建议默认：

```text
SOCKS5
127.0.0.1:10808

HTTP
127.0.0.1:10809
```

设置：

```text
本地监听
127.0.0.1

SOCKS
10808

HTTP
10809
```

默认不能监听：

```text
0.0.0.0
```

否则局域网其他设备可能连接用户代理。

若以后提供 LAN Sharing，应当：

- 独立开关；
- 明确风险提示；
- 允许访问控制。

---

# 49. 系统代理

首版推荐：

```text
System Proxy
+
Xray local SOCKS/HTTP
```

流程：

```text
macOS App
↓
Xray
↓
127.0.0.1:10808 / 10809
↓
系统 HTTP/HTTPS/SOCKS Proxy
```

应用启动代理前必须保存系统原设置。

例如：

```swift
struct OriginalProxySettings: Codable {
    var httpEnabled: Bool
    var httpHost: String?
    var httpPort: Int?

    var httpsEnabled: Bool
    var httpsHost: String?
    var httpsPort: Int?

    var socksEnabled: Bool
    var socksHost: String?
    var socksPort: Int?
}
```

停止连接：

```text
恢复原设置
```

而不是简单：

```text
关闭所有代理
```

否则会破坏用户原来的公司代理/VPN设置。

---

# 50. 网络恢复保护

这是正式客户端必须实现的。

情况：

```text
Xray 崩溃
但是系统 Proxy 仍指向 127.0.0.1:10809
```

结果：

```text
Mac 看似“断网”
```

解决：

### App 正常退出

```text
stop Xray
↓
restoreProxy()
```

### Xray 异常退出

```text
process terminationHandler
↓
restoreProxy()
```

### App 上次异常崩溃

下一次启动：

```text
检测：
系统代理 == ProxyHub 端口
AND
Xray 未运行
```

则：

```text
立即恢复备份代理
```

---

# 51. 系统代理模式的限制

有些应用不遵循系统 HTTP/SOCKS 设置。

因此：

```text
System Proxy ≠ 所有 macOS 流量
```

首版允许接受这个限制。

第二阶段增加：

```text
TUN 模式
```

Xray 当前已有 TUN inbound 支持，包括 macOS；但 TUN 涉及系统路由、DNS、IPv4/IPv6、UDP 和防止流量回环，因此应作为独立阶段实现。

---

# 52. 第二阶段：TUN

设置：

```text
代理模式

● 系统代理
○ TUN 全局
○ 规则模式
```

TUN 需要重点处理：

```text
utun
routing table
DNS
IPv6
UDP
MTU
代理服务器自身绕过
局域网绕过
Loop prevention
sleep/wake
Wi-Fi 切换
```

如果准备正式走 Apple 推荐的网络扩展模型，可评估 `NetworkExtension` 中的 App Proxy / Packet Tunnel 等能力；不同 Provider 类型的打包与分发要求不同，需要根据实际发行方式确认 entitlement 和 deployment 方案。

---

# 53. 路由模式

第一版：

```text
全局代理
直连
规则代理
```

规则代理：

```text
LAN → DIRECT
localhost → DIRECT
用户自定义域名 → DIRECT / PROXY
其他 → PROXY
```

后续可接入：

```text
geoip
geosite
```

Xray Routing 支持按规则选择不同 outbound。

---

# 54. DNS

建议至少提供：

```text
系统 DNS
自定义 DNS
通过代理 DNS
```

高级：

```text
DoH
DoQ
FakeDNS
```

但第一版不建议一次开放过多复杂选项。

重点是避免：

```text
DNS 泄漏
```

特别是在 TUN 阶段。

---

# 55. 菜单栏

macOS 强烈建议提供 MenuBarExtra。

```text
● ProxyHub

已连接
🇯🇵 日本 · Tokyo 01
32 ms

切换
🇭🇰 香港
🇯🇵 日本 ✓
🇸🇬 新加坡
🇺🇸 美国

────────
自动优选
测试当前节点
更新订阅

────────
打开 ProxyHub
断开
退出
```

---

# 56. 自动启动

设置：

```text
登录时启动             [开启]

启动后：
○ 不自动连接
● 连接上次节点
○ 自动连接最快节点
```

可使用：

```text
SMAppService.mainApp
```

控制 Login Item。

---

# 57. 安全设计

必须遵循：

```text
订阅 token
UUID
password
Shadowsocks password
Reality 敏感参数
```

尽可能放：

```text
Keychain
```

不要：

```text
UserDefaults
明文日志
crash report
普通 JSON
```

日志中：

```text
vless://UUID@host
```

显示为：

```text
vless://••••••@host
```

---

# 58. 日志

建议分：

```text
App
Subscription
Xray
Network
Test
SystemProxy
```

等级：

```text
Debug
Info
Warning
Error
```

普通用户默认：

```text
Info
```

日志界面提供：

```text
复制诊断信息
导出日志
清除
```

导出前自动脱敏：

```text
UUID
密码
Token
订阅 Query
```

---

# 59. 应用设置

```text
常规
 ├─ 登录启动
 ├─ 菜单栏
 └─ 语言

连接
 ├─ 系统代理
 ├─ SOCKS 端口
 ├─ HTTP 端口
 ├─ 自动故障切换
 └─ 网络恢复

节点
 ├─ 默认排序
 ├─ 自动国家识别
 └─ 失效节点策略

测试
 ├─ 快速测试 URL
 ├─ 并发数
 ├─ 超时
 └─ 测速数据量

订阅
 ├─ 默认更新时间
 ├─ 默认时区
 ├─ 默认更新模式
 └─ 回退天数

高级
 ├─ Xray 日志
 ├─ DNS
 ├─ Routing
 └─ Developer Mode
```

---

# 60. 订阅更新状态机

建议：

```text
idle
↓
resolvingURL
↓
fetching
↓
validating
↓
parsing
↓
deduplicating
↓
merging
↓
testing
↓
completed
```

错误：

```text
failed
```

定义：

```swift
enum SubscriptionUpdateState {
    case idle
    case resolvingURL
    case fetching
    case validating
    case parsing
    case deduplicating
    case merging
    case testing
    case completed
    case failed(String)
}
```

UI 就可以准确显示：

```text
正在解析日期地址…
正在下载…
正在解析 137 个节点…
正在测试 42/137…
完成
```

---

# 61. 自动更新核心伪代码

```swift
func update(_ subscription: Subscription) async {

    let dates = buildCandidateDates(
        offset: subscription.dateOffset,
        fallbackDays: subscription.fallbackDays,
        timeZone: subscription.timeZoneID
    )

    var payload: Data?
    var actualURL: URL?

    for date in dates {

        let resolved = resolveTemplate(
            subscription.urlTemplate ?? subscription.originalURL,
            date: date
        )

        do {
            let response = try await fetch(resolved)

            guard response.isValidHTTP else {
                continue
            }

            guard validateSubscriptionPayload(response.data) else {
                continue
            }

            payload = response.data
            actualURL = resolved
            break

        } catch {
            continue
        }
    }

    guard
        let payload,
        let actualURL
    else {
        recordFailure()
        return
    }

    let newHash = sha256(payload)

    if newHash == subscription.contentHash {
        recordNotModified(actualURL)
        return
    }

    let parsed = parseSubscription(payload)

    guard !parsed.validNodes.isEmpty else {
        recordFailure("No valid nodes")
        return
    }

    let normalized = normalize(parsed.validNodes)

    let deduplicated = deduplicate(normalized)

    let updatePlan = buildUpdatePlan(
        mode: subscription.updateMode,
        oldNodes: loadExistingNodes(),
        newNodes: deduplicated
    )

    do {
        try database.transaction {
            apply(updatePlan)
        }
    } catch {
        recordFailure(error.localizedDescription)
        return
    }

    if subscription.testAfterUpdate {
        await testNodes(updatePlan.changedNodes)
    }

    recordSuccess(actualURL, newHash)
}
```

---

# 62. “覆盖”模式的安全逻辑

即便设置了：

```text
覆盖
```

也必须：

```text
下载失败
→ 保留旧节点

解析失败
→ 保留旧节点

新内容 0 节点
→ 保留旧节点
```

可进一步加入异常保护：

假设之前：

```text
150 节点
```

新订阅只有：

```text
2 节点
```

如果减少比例超过：

```text
90%
```

可以提示：

```text
订阅节点数量异常下降
150 → 2

[保留旧节点]
[仍然覆盖]
```

自动模式默认：

```text
不执行破坏性覆盖
```

---

# 63. 更新失败重试

不要连续疯狂请求。

建议：

```text
第一次失败
↓ 1 分钟
第二次
↓ 5 分钟
第三次
↓ 30 分钟
```

当天仍失败：

```text
保持旧数据
```

并显示：

```text
订阅更新失败
当前仍使用上次成功数据
```

日期 URL 的：

```text
D0 → D-1 → D-2
```

属于“地址回退”，与网络错误 Retry 分开处理。

---

# 64. 订阅更新示例

用户添加：

```text
https://node.nodefree.me/2026/08/20260818.txt
```

系统识别：

```text
模式：
日期动态订阅

模板：
https://node.nodefree.me/{yyyy}/{MM}/{yyyyMMdd}.txt
```

用户设置：

```text
更新时间：
每天 09:00

URL 时区：
Asia/Shanghai

回退：
3 天

模式：
智能合并
```

2026-09-25 09:00：

```text
D0
https://node.nodefree.me/2026/09/20260925.txt
```

若 404：

```text
D-1
https://node.nodefree.me/2026/09/20260924.txt
```

成功后显示：

```text
本次订阅使用：
2026-09-24

原因：
2026-09-25 地址尚不可用
```

第二个例子：

```text
https://clashgithub.com/wp-content/uploads/rss/20260818.txt
```

模板：

```text
https://clashgithub.com/wp-content/uploads/rss/{yyyyMMdd}.txt
```

2026-09-25：

```text
https://clashgithub.com/wp-content/uploads/rss/20260925.txt
```

---

# 65. 手动指定更新时间

除了：

```text
每天 08:30
```

建议支持：

```text
每 6 小时
每 12 小时
每天
每 2 天
每周
手动
```

日期型订阅优先推荐：

```text
每天
```

因为 URL 通常每日变化。

对于固定地址订阅：

```text
每 6/12 小时
```

更合理。

---

# 66. 更新时不影响当前连接

如果当前连接：

```text
Node A
```

订阅更新后 Node A 仍存在：

```text
继续连接
```

不要重启。

如果 Node A 参数发生变化：

```text
标记：
“当前节点已有更新”
```

用户可以：

```text
立即应用
```

或者：

```text
下次连接应用
```

如果 Node A 被覆盖删除：

```text
当前 Xray 仍允许维持至断开
```

数据库标记：

```text
pendingRemoval
```

断开后真正清理。

这样更新订阅不会把正在工作的网络突然断掉。

---

# 67. 测试当前连接

首页提供：

```text
[测试连接]
```

结果：

```text
节点：
Tokyo Premium 01

代理：
正常

延迟：
31 ms

下载：
84.2 Mbps

UDP：
可用

出口：
Japan

IP：
xxx.xxx.xxx.xxx

DNS：
正常
```

---

# 68. “测试全部节点”

流程：

```text
用户点击测试全部
↓
构建测试 Xray config
↓
按批次测试
↓
实时写结果
↓
用户可随时取消
```

UI：

```text
正在测试 38 / 126

██████████░░░░░░ 30%

可用       31
较慢        4
失败        3

[取消]
```

测试取消：

```text
已完成结果保留
未测试节点保持原状态
```

---

# 69. 自动测试策略

订阅更新后不要默认全速测速 200 个节点。

推荐：

```text
新增节点：
快速测试

参数发生变化：
快速测试

没有变化：
不测试

用户收藏：
优先测试
```

完整带宽测试只能：

```text
用户手动触发
```

这样避免：

- 流量浪费；
- CPU 占用；
- 节点服务器被高频测速；
- 订阅源误认为异常使用。

---

# 70. 自动选最快节点

点击国家后：

```text
候选节点
↓
只取可用节点
↓
测试结果必须在有效期内
↓
按照 proxy RTT 排序
↓
连接第一名
```

结果有效期：

```text
默认 30 分钟
```

如果全部结果过期：

```text
并行快速测试前 N 个
```

例如：

```text
N = 5
```

然后选择。

---

# 71. 节点收藏

用户可以：

```text
☆ → ★
```

自动选择策略：

```text
○ 所有节点
● 优先收藏节点
○ 仅收藏节点
```

更新订阅时收藏状态不能因为节点名称变化而丢失。

依据：

```text
fingerprint
```

迁移用户 metadata。

---

# 72. 本地数据库

建议存：

```text
Subscription
ProxyNode
NodeMetadata
NodeTestResult
UpdateHistory
AppSettings
```

敏感认证字段：

```text
Keychain
```

数据库节点仅保存：

```text
credentialKey
```

---

# 73. 配置备份

可以提供：

```text
导出配置
```

但默认：

```text
不包含密码
```

高级选项：

```text
包含节点凭证
```

则必须明确提示文件含敏感信息。

---

# 74. 测试用例

## 日期模板

### Case 1

输入：

```text
https://node.nodefree.me/2026/08/20260818.txt
```

期望：

```text
https://node.nodefree.me/{yyyy}/{MM}/{yyyyMMdd}.txt
```

---

### Case 2

输入：

```text
https://clashgithub.com/wp-content/uploads/rss/20260818.txt
```

期望：

```text
https://clashgithub.com/wp-content/uploads/rss/{yyyyMMdd}.txt
```

---

### Case 3

输入：

```text
https://example.com/api?id=20260818
```

如果无法确定数字确实代表日期：

```text
要求用户确认
```

不得静默修改。

---

### Case 4

跨月：

```text
2026-08-31
→
2026-09-01
```

必须：

```text
/{yyyy}/{MM}/{yyyyMMdd}
```

正确更新月份。

---

### Case 5

跨年：

```text
2026-12-31
→
2027-01-01
```

必须正确更新：

```text
yyyy
MM
dd
```

---

### Case 6

时区：

电脑：

```text
America/New_York
```

模板时区：

```text
Asia/Shanghai
```

URL 必须以：

```text
Asia/Shanghai
```

日期为准。

---

# 75. 合并测试

### 覆盖

```text
Old:
A B C

New:
B C D

Expected:
B C D
```

### 合并

```text
Expected:
A B C D
```

### 智能合并

```text
B 参数变化
```

期望：

```text
更新 B
而不是生成 B 和 B'
```

---

# 76. 失败保护测试

必须测试：

```text
404
403
500
Timeout
TLS failure
Empty body
HTML page
Invalid Base64
Invalid YAML
0 nodes
Only invalid nodes
Interrupted download
App crash during merge
Database transaction failure
```

任何失败：

```text
不能破坏上次正常订阅
```

---

# 77. Xray 崩溃测试

步骤：

```text
连接代理
↓
强制 kill xray
```

期望：

```text
App 检测核心退出
↓
系统代理恢复
↓
UI 显示“连接中断”
```

不能留下：

```text
127.0.0.1:10809
```

但端口已经没人监听的状态。

---

# 78. 睡眠 / 唤醒测试

测试：

```text
连接
↓
Mac Sleep
↓
网络变化
↓
Wake
```

应检查：

```text
Xray 是否仍在
网络服务是否变化
代理设置是否仍正确
节点是否可用
```

如果 Wi-Fi 从：

```text
A
```

切到：

```text
B
```

需要重新验证连接。

---

# 79. Wi-Fi / 有线切换

测试：

```text
Wi-Fi → Ethernet
Ethernet → Wi-Fi
热点 → Wi-Fi
```

系统代理可能按 Network Service 保存，因此不能只在 App 启动时检测一次。

必须监听网络变化。

---

# 80. IPv6 测试

至少覆盖：

```text
IPv4 only
IPv6 only
Dual Stack
```

防止出现：

```text
IPv4 代理
+
IPv6 直连
```

导致用户认为已经代理但 IPv6 出口仍是本地。

---

# 81. 首版开发顺序

## Phase 1

完成：

```text
SwiftUI Shell
节点模型
VLESS/VMess/Trojan/SS Parser
Base64 Subscription
订阅管理
```

## Phase 2

```text
XrayConfigBuilder
XrayProcessManager
SOCKS/HTTP
连接/断开
```

## Phase 3

```text
macOS System Proxy
原设置备份
Crash Restore
```

## Phase 4

```text
节点快速测试
测试全部
出口 IP
国家识别
```

## Phase 5

```text
日期型订阅
自动模板识别
定时更新
日期回退
覆盖/合并/智能合并
```

## Phase 6

```text
Menu Bar
Login Item
LaunchAgent
后台更新
```

## Phase 7

```text
Routing
DNS
完整测速
UDP
IPv6
```

## Phase 8

```text
TUN
NetworkExtension / 系统级集成评估
```

---

# 82. 首版验收标准

V1 可以定义为：

- [ ] 可添加固定订阅；
- [ ] 可添加日期型订阅；
- [ ] 自动识别 `{yyyy}/{MM}/{yyyyMMdd}`；
- [ ] 用户可以手工修改 URL Template；
- [ ] 可以设置每天具体更新时间；
- [ ] 可以设置 URL 日期时区；
- [ ] 可以设置日期 offset；
- [ ] 当日 URL 失败可自动向前回退；
- [ ] 支持覆盖；
- [ ] 支持合并；
- [ ] 支持智能合并；
- [ ] 更新失败不会删除旧节点；
- [ ] 支持 VLESS；
- [ ] 支持 VMess；
- [ ] 支持 Trojan；
- [ ] 支持 Shadowsocks；
- [ ] 支持 Base64 订阅；
- [ ] 支持 Clash YAML；
- [ ] 自动去重；
- [ ] 国家自动分类；
- [ ] 节点快速测试；
- [ ] 全部节点批量测试；
- [ ] 出口 IP 测试；
- [ ] 一键按国家连接；
- [ ] 自动选最快节点；
- [ ] 自动故障切换；
- [ ] Xray-core 启停；
- [ ] 系统代理启停；
- [ ] 系统原代理恢复；
- [ ] Xray 崩溃恢复；
- [ ] 菜单栏切换；
- [ ] 登录启动；
- [ ] 日志脱敏；
- [ ] Keychain 保存敏感凭证。

达到以上内容后已经可以作为一个完整的 macOS 可视化代理客户端使用。

---

# 83. 推荐默认配置

建议默认值：

```text
代理模式：
System Proxy

SOCKS：
127.0.0.1:10808

HTTP：
127.0.0.1:10809

节点测试：
快速测试

测试并发：
8

单节点超时：
8 秒

测试结果有效期：
30 分钟

自动故障切换：
开启

故障候选：
3 个

订阅自动更新：
开启

默认更新：
每天 08:30

日期订阅默认时区：
Asia/Shanghai

日期回退：
3 天

更新模式：
智能合并

更新后：
仅测试新增/变化节点

日志：
Info

敏感字段：
自动脱敏
```

---

# 84. 关键设计结论

本项目最重要的几个原则：

### 1. Xray 只做网络核心

Swift App 负责：

```text
UI
订阅
日期
节点
测试
调度
系统设置
```

Xray 负责：

```text
协议
连接
路由
代理
```

不要自己重新实现 VLESS/VMess 等核心协议。

### 2. 订阅更新必须先验证再覆盖

永远是：

```text
下载
→ 验证
→ 解析
→ 临时结果
→ 事务替换
```

不能：

```text
清空旧数据
→ 再下载
```

### 3. 日期 URL 使用 Template

不要针对某个站点写：

```text
if host == nodefree
```

而是统一：

```text
{yyyy}
{MM}
{dd}
{yyyyMMdd}
```

这样未来任何类似订阅都可以使用。

### 4. 测速不能只 Ping

真正可用性应该经过：

```text
配置
→ DNS
→ TCP
→ Xray
→ HTTP
→ 出口 IP
```

### 5. 系统代理一定要能恢复

连接失败、Xray 崩溃、App 崩溃、Mac 重启，都不能导致系统永久指向一个失效的 localhost Proxy。

---

# 85. 建议后续版本

## V1.1

- 二维码扫描；
- PAC；
- 自定义路由规则；
- 节点标签；
- 节点备注；
- 节点收藏；
- 节点历史质量。

## V1.2

- TUN；
- UDP；
- IPv6；
- DNS 防泄漏；
- FakeDNS；
- 分应用路由。

## V1.3

- 节点健康趋势；
- 自动故障切换；
- 根据延迟自动切换；
- 定期后台健康检查；
- 订阅版本回滚。

---

# 86. 官方技术参考

Xray-core：

https://github.com/XTLS/Xray-core

Xray 配置文档：

https://xtls.github.io/en/config/

Xray Routing：

https://xtls.github.io/en/config/routing

Xray TUN：

https://github.com/XTLS/Xray-core/blob/main/proxy/tun/README.md

Apple Network Extension：

https://developer.apple.com/documentation/NetworkExtension

Apple App Proxy Provider：

https://developer.apple.com/documentation/NetworkExtension/app-proxy-provider

Apple Service Management / SMAppService：

https://developer.apple.com/documentation/servicemanagement/smappservice

---

# 87. 下一阶段建议直接开始的代码模块

建议真正进入编码时按下面 5 个文件先做：

```text
ProxyNode.swift
Subscription.swift
SubscriptionDateTemplate.swift
SubscriptionParser.swift
XrayConfigBuilder.swift
```

然后完成：

```text
SubscriptionFetcher
↓
DateTemplate
↓
Parser
↓
Node Database
↓
XrayConfigBuilder
↓
XrayProcessManager
↓
SystemProxyManager
```

这条链打通以后：

> **粘贴订阅 → 节点出现 → 选择国家 → 启动代理**

核心功能就已经跑通。

之后再加入：

```text
测试
定时更新
后台 Agent
TUN
```

即可逐步升级为完整产品。
